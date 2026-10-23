-- Questie readiness and refresh, saved variables, the chat lines on level up and dungeon entry, and the native events.
local ADDON_NAME, ns = ...

local UI = LibStub("LibNativeUI-1.0")

local ADDON_TITLE = ns.ADDON_TITLE
local DEFAULTS = ns.DEFAULTS
local SORT_BY_OPTIONS = ns.SORT_BY_OPTIONS
local SORT_DIR_OPTIONS = ns.SORT_DIR_OPTIONS
local findMissingField = ns.findMissingField
local describeQuestieState = ns.describeQuestieState
local clampRange = ns.clampRange
local sessionCache = ns.sessionCache
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
local installMapIconHooks = ns.installMapIconHooks
local formatZoneLink = ns.formatZoneLink
local setupLauncher = ns.setupLauncher

local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
local AvailableQuests = QuestieLoader:ImportModule("AvailableQuests")

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
    if not ns.questieReady then
        return
    end
    local currentLog = QuestiePlayer.currentQuestlog
    local counts, zones, zoneAreaIds = {}, {}, {}
    local total = 0
    for questId in pairs(QuestieDB.QuestPointers) do
        if QuestieDB.QueryQuestSingle(questId, "requiredLevel") == newLevel
            and not currentLog[questId]
            and not isQuestCompleted(questId)
            and hasReachableStarter(questId)
            and QuestieDB.IsDoable(questId) then
            local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
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
    local more = #zones > 3 and string.format(" and %d more zones", #zones - 3) or ""
    UI.Print(ADDON_TITLE, "New quests at level " .. newLevel .. ": " .. table.concat(parts, ", ") .. more .. ".")
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
        UI.Print(ADDON_TITLE, string.format("%s: %d quest%s you could still pick up.", formatZoneLink(zoneName, areaId), count, count == 1 and "" or "s"))
    end
end

-- Questie calls this after its own state changed. Objective progress only re-renders (the completed section reads live completeness); accept, turn-in and abandon change the zone buckets, so they rescan. The debounce also covers the accept path, where Questie adds the quest to its log right after the callback.
local function onQuestUpdate(_, _, triggerReason)
    if triggerReason ~= Questie.API.Enums.QuestUpdateTriggerReason.QUEST_UPDATED then
        invalidateScan()
    end
    scheduleRefresh()
end

-- Questie rewrites composed rows when a Policy Correction lands after login (its Darkmoon Faire NPC slot waits for the calendar). Item repairs only fix names, which nothing here caches; NPC, object and quest writes can move givers, turn-ins and chains.
local function onCorrectionApplied(datatype)
    if datatype == "Item" then
        return
    end
    wipe(sessionCache.startInfo)
    wipe(sessionCache.finishInfo)
    wipe(sessionCache.reachable)
    if datatype == "Quest" then
        sessionCache.followers = nil
        sessionCache.itemQuests = nil
        scheduleItemQuestIndexBuild()
    end
    invalidateScan()
    scheduleRefresh()
end

-- Questie resets its level-requirement cache whenever its Quest Level Options change and on level-up, so under Questie's range the list rescans with it.
local function onQuestieLevelRangeChanged()
    if QuestieGuideDB.useQuestieLevelRange then
        invalidateScan()
        scheduleRefresh()
    end
end

-- Runs once Questie.API reports ready: after Questie's Stage 3 installed its tooltip post-calls and filled its quest log and completed set.
local function onQuestieReady()
    ns.missingQuestieField = findMissingField()
    if ns.missingQuestieField then
        UI.Print(ADDON_TITLE, describeQuestieState())
        return
    end
    ns.questieReady = true
    installItemTooltipHooks()
    installMapIconHooks()
    hooksecurefunc(QuestieDB, "RefreshAfterCorrectionApply", onCorrectionApplied)
    hooksecurefunc(AvailableQuests, "ResetLevelRequirementCache", onQuestieLevelRangeChanged)
    Questie.API.RegisterForQuestUpdates(onQuestUpdate)
    scheduleItemQuestIndexBuild()
end

-- Questie.API is the stable part of Questie; without it the guide stays closed.
local function registerWithQuestie()
    local api = Questie.API
    if not (api and api.RegisterOnReady and api.RegisterForQuestUpdates and api.Enums and api.Enums.QuestUpdateTriggerReason) then
        ns.missingQuestieField = "Questie.API"
        return
    end
    api.RegisterOnReady(onQuestieReady)
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

local function loadSavedVariables()
    if type(QuestieGuideDB) ~= "table" then
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

-- Quest events come from Questie (onQuestUpdate); only the player's own level and location are native events.
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_LEVEL_CHANGED")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:SetScript("OnEvent", function(_, event, arg, newLevel)
    if event == "PLAYER_LEVEL_CHANGED" then
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
        registerWithQuestie()
    elseif event == "PLAYER_LOGIN" then
        setupLauncher()
    end
end)
