-- Saved variables, the quest and level events that refresh the list, and the chat lines on level up and dungeon entry.
local ADDON_NAME, ns = ...

local DEFAULTS = ns.DEFAULTS
local SORT_BY_OPTIONS = ns.SORT_BY_OPTIONS
local SORT_DIR_OPTIONS = ns.SORT_DIR_OPTIONS
local clampRange = ns.clampRange
local isQuestCompleted = ns.isQuestCompleted
local getZoneName = ns.getZoneName
local getEffectiveLevel = ns.getEffectiveLevel
local passesLevelCap = ns.passesLevelCap
local hasReachableStarter = ns.hasReachableStarter
local getCurrentZoneName = ns.getCurrentZoneName
local scanCache = ns.scanCache
local invalidateScan = ns.invalidateScan
local countPickable = ns.countPickable
local renderList = ns.renderList
local installItemTooltipHooks = ns.installItemTooltipHooks
local scheduleItemQuestIndexBuild = ns.scheduleItemQuestIndexBuild
local formatZoneLink = ns.formatZoneLink
local setupLauncher = ns.setupLauncher
local getQuestLog = ns.getQuestLog
local questField = ns.questField
local getAllQuestIds = ns.getAllQuestIds
local isDoable = ns.isDoable

local refreshTimer
local function scheduleRefresh()
    if not ns.mainFrame or not ns.mainFrame:IsShown() then
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

-- Level-up line: quests whose level requirement is exactly the new level, so each quest announces once. Gates mirror the discovery scan (doable, reachable starter, real zone) so the line only names quests the window would list.
local function announceNewQuests(newLevel)
    local currentLog = getQuestLog()
    local counts, zones, zoneAreaIds = {}, {}, {}
    local total = 0
    for _, questId in ipairs(getAllQuestIds()) do
        if questField(questId, "requiredLevel") == newLevel
            and not currentLog[questId]
            and not isQuestCompleted(questId)
            and hasReachableStarter(questId)
            and isDoable(questId) then
            local zoneOrSort = questField(questId, "zoneOrSort")
            local level, requiredLevel = getEffectiveLevel(questId, newLevel)
            if zoneOrSort and passesLevelCap(level, requiredLevel) then
                local zoneName = getZoneName(zoneOrSort)
                if not counts[zoneName] then
                    counts[zoneName] = 0
                    zones[#zones + 1] = zoneName
                    zoneAreaIds[zoneName] = zoneOrSort
                end
                counts[zoneName] = counts[zoneName] + 1
                total = total + 1
            end
        end
    end
    if total == 0 then
        return
    end
    table.sort(zones, function(a, b)
        if counts[a] ~= counts[b] then
            return counts[a] > counts[b]
        end
        return a < b
    end)

    -- Zone names print as clickable links; a sort-category bucket ("Other") carries no real area id, so it prints plain.
    local parts = {}
    for i = 1, math.min(#zones, 3) do
        local zoneName = zones[i]
        local areaId = zoneAreaIds[zoneName]
        local label = (areaId and areaId > 0) and formatZoneLink(zoneName, areaId) or zoneName
        parts[i] = string.format("%d in %s", counts[zoneName], label)
    end
    local more = #zones > 3 and string.format(" and %d more |4zone:zones;", #zones - 3) or ""
    ns.Print("New quests at level " .. newLevel .. ": " .. table.concat(parts, ", ") .. more .. ".")
end

-- The instance the last dungeon line named, so one visit prints one line; cleared on leaving instances.
local announcedInstance

-- Entering a dungeon or raid names how many of its quests the player could still pick up. Reads the last scan, even one a quest accept has since marked stale, so it never starts the database walk and stays silent until the window was opened once this session.
local function announceInstanceQuests()
    local _, instanceType = IsInInstance()
    if instanceType ~= "party" and instanceType ~= "raid" then
        announcedInstance = nil
        return
    end
    if not scanCache.byZone then
        return
    end
    local zoneName, areaId = getCurrentZoneName()
    local entry = zoneName and scanCache.byZone[zoneName]
    if not entry or zoneName == announcedInstance then
        return
    end
    announcedInstance = zoneName
    local count = countPickable(entry)
    if count > 0 then
        ns.Print(string.format("%s: %d |4quest:quests; you could still pick up.", formatZoneLink(zoneName, areaId), count))
    end
end

-- Fills every missing or mistyped saved key from the defaults, nested tables included, so a new filter key arrives in old saved variables too.
local function applyDefaults(db, defaults)
    for key, default in pairs(defaults) do
        if type(db[key]) ~= type(default) then
            db[key] = type(default) == "table" and CopyTable(default) or default
        elseif type(default) == "table" then
            applyDefaults(db[key], default)
        end
    end
end

local function isKnownOption(options, value)
    for _, opt in ipairs(options) do
        if opt.value == value then
            return true
        end
    end
    return false
end

-- An absent table marks the account's first load with the addon; the welcome line prints for it at login.
local function loadSavedVariables()
    if type(QuestieGuideDB) ~= "table" then
        ns.firstRun = true
        QuestieGuideDB = {}
    end
    applyDefaults(QuestieGuideDB, DEFAULTS)
    QuestieGuideDB.levelBelow = clampRange(QuestieGuideDB.levelBelow)
    QuestieGuideDB.levelAbove = clampRange(QuestieGuideDB.levelAbove)
    if not isKnownOption(SORT_BY_OPTIONS, QuestieGuideDB.sortMode) then
        QuestieGuideDB.sortMode = DEFAULTS.sortMode
    end
    if not isKnownOption(SORT_DIR_OPTIONS, QuestieGuideDB.sortDir) then
        QuestieGuideDB.sortDir = DEFAULTS.sortDir
    end
end

-- Accept, remove and turn-in change which quests list, so they rescan; objective progress only re-renders, since the completed section reads live completeness. A loading screen rebuilds the player's quest sets.
local WATCHED_EVENTS = { "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_WATCH_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_CHANGED", "ZONE_CHANGED_NEW_AREA" }

local QUEST_STATE_HANDLERS = {
    QUEST_ACCEPTED = ns.onQuestAccepted,
    QUEST_REMOVED = ns.onQuestRemoved,
    QUEST_TURNED_IN = ns.onQuestTurnedIn,
}

-- Without QuestieDB the window never opens, so only the saved variables and the launcher load and no quest event is watched.
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg, newLevel)
    local updateState = QUEST_STATE_HANDLERS[event]
    if updateState then
        updateState(arg)
        invalidateScan()
        scheduleRefresh()
    elseif event == "QUEST_WATCH_UPDATE" then
        scheduleRefresh()
    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.resetPlayerQuests()
    elseif event == "PLAYER_LEVEL_CHANGED" then
        invalidateScan()
        scheduleRefresh()

        -- Only a gained level unlocks quests. The wait lets the level-up celebration's frame spike pass before the quest DB walk.
        if newLevel > arg then
            C_Timer.After(1, function()
                announceNewQuests(newLevel)
            end)
        end
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        -- Zone changes only move the current-zone header marker, which reads location at render, so the scan cache survives.
        scheduleRefresh()
        announceInstanceQuests()
    elseif event == "ADDON_LOADED" and arg == ADDON_NAME then
        loadSavedVariables()
        if ns.questDB then
            FrameUtil.RegisterFrameForEvents(self, WATCHED_EVENTS)
            installItemTooltipHooks()
        end
    elseif event == "PLAYER_LOGIN" then
        setupLauncher()
        if ns.questDB then
            scheduleItemQuestIndexBuild()
        end
    end
end)
