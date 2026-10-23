-- Row text in Forever's quest log format, the quest, chain, zone and turn-in tooltips, and the quest lines on item tooltips.
local _, ns = ...

local UI = LibStub("LibNativeUI-1.0")

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

local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
local QuestieLib = QuestieLoader:ImportModule("QuestieLib")
local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
local QuestieTooltips = QuestieLoader:ImportModule("QuestieTooltips")

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
    GameTooltip_AddColoredDoubleLine(tooltip, label, tostring(value), UI.Color.heading, UI.Color.body)
end

-- Questie's difficulty colour (red/orange/yellow/green/grey), so the level brackets and name share the hue of Questie's own titles, which prefer the client's per-quest difficulty.
local function getDifficultyColor(level, questId)
    return CreateColor(QuestieLib:GetDifficultyColorPercent(level, questId))
end

local function showQuestTooltip(anchor, questId)
    local quest = QuestieDB.GetQuest(questId)
    if not quest then
        return
    end

    UI.ShowTooltip(anchor, function(tooltip)
        GameTooltip_SetTitle(tooltip, QuestieLib:GetColoredQuestName(questId, true, false))
        GameTooltip_AddBlankLineToTooltip(tooltip)

        if quest.requiredLevel and quest.requiredLevel > 0 then
            GameTooltip_AddHighlightLine(tooltip, ITEM_MIN_LEVEL:format(quest.requiredLevel))
        end

        if QuestieDB.IsRepeatable(questId) then
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

        if type(quest.objectivesText) == "table" and #quest.objectivesText > 0 then
            GameTooltip_AddBlankLineToTooltip(tooltip)
            GameTooltip_AddNormalLine(tooltip, "Objectives")
            for _, line in ipairs(quest.objectivesText) do
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

-- Two-line row presentation in Forever's quest log format, "[12+] Quest name (Dungeon) [badge?]", over the giver's zone and name. Level and quest name share Questie's difficulty colour; the tag and the whole giver line are muted grey so they read as secondary. `badge` is appended to line 1 when provided.
local function formatRowLines(quest, badge)
    local tagId, isElite = getQuestTag(quest.id)
    local title = string.format("[%d%s] %s", quest.level or 0, isElite and "+" or "", quest.name or "")
    local line1 = getDifficultyColor(quest.level, quest.id):WrapTextInColorCode(title)
    if QUEST_TAG_TEXT[tagId] then
        line1 = line1 .. " " .. COLOR.MUTED:WrapTextInColorCode(PARENS_TEMPLATE:format(QUEST_TAG_TEXT[tagId]))
    end
    if badge then
        line1 = line1 .. " " .. badge
    end

    local giverLine = formatGiverLine(resolveStartInfo(quest))
    return line1, giverLine and COLOR.MUTED:WrapTextInColorCode(giverLine)
end

-- Status badge for prior quests in the chain tooltip. `[In Questlog]` if the player has the quest in their log, `[Available]` if it can be picked up right now, `[Requires Level N]` if only its level requirement stands in the way (IsDoable ignores it), otherwise no badge. Completed quests don't appear in the chain at all (findMissingChains skips them).
local function getStatusBadge(questId)
    if QuestiePlayer.currentQuestlog[questId] then
        return COLOR.IN_LOG:WrapTextInColorCode("[In Questlog]")
    end
    if QuestieDB.IsDoable(questId) then
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
    UI.ShowTooltip(anchor, function(tooltip)
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
    UI.ShowTooltip(anchor, function(tooltip)
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

-- Tooltip for a ready-to-turn-in quest: Questie-colored name plus the turn-in target, mirroring showQuestTooltip's field styling. The quest's startInfo carries the finisher (see collectCompletedByZone).
local function showTurnInTooltip(anchor, quest)
    UI.ShowTooltip(anchor, function(tooltip)
        GameTooltip_SetTitle(tooltip, QuestieLib:GetColoredQuestName(quest.id, true, false))
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

-- List every quest the item belongs to that is NOT in the quest log, styled like Questie's active-quest titles (difficulty-colored name via GetColoredQuestName plus a Questie:Colorize'd "(Status)" suffix, the same pattern as its "(Complete)"), so they read as part of Questie's block. Active quests stay Questie's job; adding them here would duplicate its title and objective lines.
local INDEX_BUILD_DELAY = 5
local indexBuildScheduled = false

local ITEM_QUEST_KEYS = { "objectives", "sourceItemId", "requiredSourceItems" }

-- sessionCache.itemQuests: itemId -> quest ids referencing the item (objectives, quest-provided, required source), built from Questie's compiled quest DB.
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
    for questId in pairs(QuestieDB.QuestPointers) do
        local fields = QuestieDB.QueryQuest(questId, ITEM_QUEST_KEYS)
        if fields then
            local objectives = fields[1]
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
            add(fields[2], questId)
            if type(fields[3]) == "table" then
                for _, itemId in ipairs(fields[3]) do
                    add(itemId, questId)
                end
            end
        end
    end
    sessionCache.itemQuests = index
end

-- A few seconds after Questie reports ready, so the walk doesn't share a frame with Questie's own available-quest draw at the end of its init.
local function scheduleItemQuestIndexBuild()
    if indexBuildScheduled then
        return
    end
    indexBuildScheduled = true
    C_Timer.After(INDEX_BUILD_DELAY, buildItemQuestIndex)
end

-- Classifies a non-log quest for the item tooltip; nil skips the line. Skipped entirely: active quests (Questie renders them), hidden or race/class-gated quests, and permanently unobtainable ones. A quest the player is too low for reads "Requires Level N", the list's own wording (ITEM_MIN_LEVEL), in the grey of Questie's level-locked pin; "Upcoming" is left for prereq-blocked quests.
local function getItemQuestStatus(questId, playerLevel, currentLog)
    if currentLog[questId] then
        return nil
    end
    if isQuestCompleted(questId) then
        return "Completed Before", "gray"
    end
    if isQuestHidden(questId) or not matchesPlayerFaction(questId) then
        return nil
    end
    local level, requiredLevel, requiredMaxLevel = getEffectiveLevel(questId, playerLevel)
    if not passesLevelCap(level, requiredLevel) or exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel) then
        return nil
    end
    if not meetsRequiredLevel(requiredLevel, playerLevel) then
        return ITEM_MIN_LEVEL:format(requiredLevel), "gray"
    end
    if QuestieDB.IsDoable(questId) then
        return "Available", "green"
    end
    if isBlockedByPrereqs(questId) then
        return "Upcoming", "yellow"
    end
    return nil
end

-- True when Questie already names this quest on the item tooltip via its start-item line, registered by its own item handler on the same hover before ours runs.
local function questieShowsStartLine(itemId, questId, profile)
    if not profile.showQuestsInNpcTooltip then
        return false
    end
    local entries = QuestieTooltips.lookupByKey["i_" .. itemId]
    if not entries then
        return false
    end
    for _, entry in pairs(entries) do
        if entry.questId == questId and entry.name then
            return true
        end
    end
    return false
end

-- Per-frame dedup mirroring Questie's item handler: the post-call can fire repeatedly for one hover, so re-add only when the tooltip shows a different item or was rebuilt (fewer lines than when we last added).
local lastTooltipItem = {}

local function addQuestLinesToItemTooltip(tooltip, itemId)
    local itemQuests = sessionCache.itemQuests
    if tooltip:IsForbidden() or not itemId or not itemQuests then
        return
    end
    local profile = Questie.db.profile
    if not profile.enableTooltips then
        return
    end
    local last = lastTooltipItem[tooltip]
    if last and last.itemId == itemId and tooltip:NumLines() >= last.count then
        return
    end
    local currentLog = QuestiePlayer.currentQuestlog
    local playerLevel = UnitLevel("player")
    local questIds = {}
    local seen = {}
    for _, questId in ipairs(itemQuests[itemId] or {}) do
        seen[questId] = true
        questIds[#questIds + 1] = questId
    end
    local startQuestId = QuestieDB.QueryItemSingle(itemId, "startQuest")
    if startQuestId and startQuestId > 0 and not seen[startQuestId] then
        questIds[#questIds + 1] = startQuestId
    end
    for _, questId in ipairs(questIds) do
        local label, color = getItemQuestStatus(questId, playerLevel, currentLog)

        -- Drop the Available label when it would only repeat Questie's own start-item line; other statuses add information that line lacks.
        if label == "Available" and questId == startQuestId and questieShowsStartLine(itemId, questId, profile) then
            label = nil
        end
        if label then
            local status = Questie:Colorize("(" .. label .. ")", color)
            tooltip:AddLine(QuestieLib:GetColoredQuestName(questId, profile.enableTooltipsQuestLevel, false) .. " " .. status)
        end
    end
    lastTooltipItem[tooltip] = { itemId = itemId, count = tooltip:NumLines() }
end

-- Hooks the same two tooltips Questie's item handler hooks. Installed from the ready callback, after Questie's Stage 3 registered its own post-call, and post-calls run in registration order, so these lines land under Questie's.
local function installItemTooltipHooks()
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then
            return
        end

        -- Forever hides tooltip data as secret values inside instances and in some combat cases, as Questie's own tooltip handler notes; a secret can't be read or used as a key.
        if type(data) ~= "table" or issecrettable(data) then
            return
        end
        local itemId = data.id
        if issecretvalue(itemId) or type(itemId) ~= "number" then
            return
        end
        addQuestLinesToItemTooltip(tooltip, itemId)
    end)
    for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
        tooltip:HookScript("OnHide", function(self)
            lastTooltipItem[self] = nil
        end)
    end
end

ns.formatLevelLock = formatLevelLock
ns.formatRowLines = formatRowLines
ns.showQuestTooltip = showQuestTooltip
ns.showChainTooltip = showChainTooltip
ns.getLevelShare = getLevelShare
ns.showZoneTooltip = showZoneTooltip
ns.showTurnInTooltip = showTurnInTooltip
ns.installItemTooltipHooks = installItemTooltipHooks
ns.scheduleItemQuestIndexBuild = scheduleItemQuestIndexBuild
