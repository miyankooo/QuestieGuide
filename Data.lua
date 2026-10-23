-- Questie data lookups: quest facts, givers and turn-ins, the level band, reachability and prerequisites.
local _, ns = ...

local MAX_CHAIN_DEPTH = ns.MAX_CHAIN_DEPTH

local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
local QuestieLib = QuestieLoader:ImportModule("QuestieLib")
local ZoneDB = QuestieLoader:ImportModule("ZoneDB")
local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
local QuestXP = QuestieLoader:ImportModule("QuestXP")
local QuestieCorrections = QuestieLoader:ImportModule("QuestieCorrections")
local QuestieCompat = QuestieLoader:ImportModule("QuestieCompat")
local QuestieEvent = QuestieLoader:ImportModule("QuestieEvent")

-- Questie's own completed-quest set, the one its IsDoable and prerequisite checks read. Questie replaces the table on a quest log reset, so it's read fresh every call.
local function isQuestCompleted(questId)
    return Questie.db.char.complete[questId] and true or false
end

-- A quest's tag id and elite flag, the way Forever's quest log shows them: one tag after the name and a "+" after the level (Camelot QuestUtilsOverrides). The tag id comes from Questie's corrected cache, which fills a second after its first miss, so callers read it at render, never from the scan. Questie keeps no elite flag, so that one is native.
local function getQuestTag(questId)
    return QuestieDB.GetQuestTagInfo(questId), C_QuestLog.IsEliteQuest(questId)
end

-- Questie's XP estimate after its level and buff adjustments; pcall keeps one failing estimate from breaking the whole scan.
local function getQuestXp(questId)
    local ok, xp = pcall(QuestXP.GetQuestLogRewardXP, QuestXP, questId, true)
    return (ok and type(xp) == "number") and xp or 0
end

-- The catch-all bucket for quests whose zoneOrSort is a sort category rather than a real area id. Pinned to the bottom of the list by sortZones because it's mostly noise (class quests, faction quests, profession quests, ...).
local OTHER_ZONE_NAME = "Other"

-- zoneOrSort > 0 is a Blizzard area ID; <= 0 is a sort category we collapse into "Other". Names are static client data, and the scan plus the chain projection resolve them for thousands of quests per rescan, so results cache for the session.
local zoneNameCache = {}

-- Resolves names the way Questie's tracker does: the client area table first, then Questie's dungeon list.
local function getZoneName(zoneOrSort)
    if not zoneOrSort or zoneOrSort <= 0 then
        return OTHER_ZONE_NAME
    end
    local cached = zoneNameCache[zoneOrSort]
    if cached then
        return cached
    end
    local name = C_Map.GetAreaInfo(zoneOrSort) or ZoneDB:GetLocalizedDungeonName(zoneOrSort) or ("Zone " .. zoneOrSort)
    zoneNameCache[zoneOrSort] = name
    return name
end

-- Mirrors the hidden-quest exclusions IsDoable applies before its prereq logic: Questie's curated blacklist, quests the player hid manually, and IsDoable's own autoBlacklist verdicts. Needed wherever quests are classified after IsDoable already said no (missing-prereq rows, chain projection), because those paths never receive IsDoable's verdict on hidden state and would otherwise resurrect blacklisted or inactive-event quests.
local function isQuestHidden(questId)
    if QuestieCorrections.hiddenQuests[questId] or QuestieDB.autoBlacklist[questId] then
        return true
    end
    return Questie.db.char.hidden[questId] and true or false
end

-- Questie's effective levels, which resolve scaling quests (questLevel -1) to the player's level; a quest without its own level falls back to its required level.
local function getEffectiveLevel(questId, playerLevel)
    local level, requiredLevel, requiredMaxLevel = QuestieLib.GetEffectiveQuestLevel(questId, playerLevel)
    requiredLevel = requiredLevel or 0
    if level and level > 0 then
        return level, requiredLevel, requiredMaxLevel or 0
    end
    return requiredLevel, requiredLevel, requiredMaxLevel or 0
end

-- Questie's database can carry quests above the level cap; they can never be picked up.
local function passesLevelCap(level, requiredLevel)
    local maxLevel = GetMaxPlayerLevel()
    return level <= maxLevel and requiredLevel <= maxLevel
end

local function getQuestName(questId)
    return QuestieDB.QueryQuestSingle(questId, "name") or ("Quest " .. questId)
end

-- Session caches over static Questie data, keyed by quest id; onCorrectionApplied drops them when Questie rewrites its rows.
local sessionCache = { startInfo = {}, finishInfo = {}, reachable = {}, followers = nil, itemQuests = nil }

-- Questie stores a spawn without a map position (dungeon interiors) as {-1, -1}; such a spawn still names its zone but must not show coordinates or set a waypoint.
local function getSpawnCoords(spawn)
    local x, y = type(spawn) == "table" and spawn[1], type(spawn) == "table" and spawn[2]
    if type(x) == "number" and type(y) == "number" and x >= 0 and y >= 0 and (x > 0 or y > 0) then
        return spawn
    end
    return nil
end

-- Picks a spawn from Questie's per-zone spawn table: prefer the quest's own zone (zoneOrSort) so the labeled location matches the bucket; fall back to the smallest area id when no spawn lives there (deterministic, but arbitrary). Zone and spawn always come from the same entry.
local function pickPreferredSpawn(spawns, preferZoneId)
    local preferredZoneId, preferredSpawn
    local fallbackZoneId, fallbackSpawn
    for zoneId, list in pairs(spawns) do
        if type(list) == "table" and list[1] then
            if preferZoneId and zoneId == preferZoneId then
                preferredZoneId = zoneId
                preferredSpawn = list[1]
            elseif not fallbackZoneId or zoneId < fallbackZoneId then
                fallbackZoneId = zoneId
                fallbackSpawn = list[1]
            end
        end
    end
    if preferredZoneId then
        return preferredZoneId, getSpawnCoords(preferredSpawn)
    end
    return fallbackZoneId, getSpawnCoords(fallbackSpawn)
end

local function getPreferredZoneId(questId)
    local questZone = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
    return (questZone and questZone > 0) and questZone or nil
end

-- Name, zone name, spawn and area id of an NPC, located in the quest's own zone when it spawns there.
local function describeNpcForQuest(npcId, questId)
    local npc = QuestieDB:GetNPC(npcId)
    if not npc then
        return nil
    end
    if type(npc.spawns) ~= "table" then
        return npc.name, nil, nil, nil
    end
    local bestZoneId, bestSpawn = pickPreferredSpawn(npc.spawns, getPreferredZoneId(questId))
    if not bestZoneId then
        return npc.name, nil, nil, nil
    end
    return npc.name, getZoneName(bestZoneId), bestSpawn, bestZoneId
end

-- Returns name, zoneName, {x, y}, areaId for the quest's start source. Questie's `startedBy` is a 3-tuple: [1] NPC ids, [2] object ids, [3] item ids. Object/item start (no NPC giver): use the quest's own zone as a best-effort location and "Quest Item" as the generic giver name.
local function computeQuestStartInfo(questId)
    local startedBy = QuestieDB.QueryQuestSingle(questId, "startedBy")
    if type(startedBy) ~= "table" then
        return nil, nil, nil, nil
    end

    local npcIds = startedBy[1]
    if type(npcIds) == "table" and npcIds[1] then
        local npcName, zoneName, spawn, areaId = describeNpcForQuest(npcIds[1], questId)
        if npcName then
            return npcName, zoneName, spawn, areaId
        end
    end

    local hasObjectStart = type(startedBy[2]) == "table" and startedBy[2][1] ~= nil
    local hasItemStart = type(startedBy[3]) == "table" and startedBy[3][1] ~= nil
    if hasObjectStart or hasItemStart then
        local questZone = getPreferredZoneId(questId)
        if questZone then
            return "Quest Item", getZoneName(questZone), nil, questZone
        end
        return "Quest Item", nil, nil, nil
    end

    return nil, nil, nil, nil
end

-- Start info is static DB data, but the scan resolves it for every doable quest on every rescan (accept, turn-in, level-up) and quest row tables are rebuilt each scan, so a per-row cache would not survive. Cache per questId for the session instead.
local function getQuestStartInfo(questId)
    local cached = sessionCache.startInfo[questId]
    if cached then
        return cached.npcName, cached.zoneName, cached.spawn, cached.areaId
    end
    local npcName, zoneName, spawn, areaId = computeQuestStartInfo(questId)
    sessionCache.startInfo[questId] = { npcName = npcName, zoneName = zoneName, spawn = spawn, areaId = areaId }
    return npcName, zoneName, spawn, areaId
end

-- Row and tooltip callers keep the table shape they already use; it fronts the session cache.
local function resolveStartInfo(quest)
    if quest.startInfo then
        return quest.startInfo
    end
    local npcName, zoneName, spawn, areaId = getQuestStartInfo(quest.id)
    quest.startInfo = {
        npcName = npcName,
        zoneName = zoneName,
        spawn = spawn,
        areaId = areaId,
    }
    return quest.startInfo
end

-- Returns name, zoneName, {x, y}, areaId for the quest's turn-in target. Questie's `finishedBy` is a 2-tuple: [1] NPC ids, [2] object ids. The turn-in location only exists in Questie's data.
local function computeQuestFinishInfo(questId)
    local finishedBy = QuestieDB.QueryQuestSingle(questId, "finishedBy")
    if type(finishedBy) ~= "table" then
        return nil, nil, nil, nil
    end

    local npcIds = finishedBy[1]
    if type(npcIds) == "table" and npcIds[1] then
        local npcName, zoneName, spawn, areaId = describeNpcForQuest(npcIds[1], questId)
        if npcName then
            return npcName, zoneName, spawn, areaId
        end
    end

    local objectIds = finishedBy[2]
    if type(objectIds) == "table" and objectIds[1] then
        local name = QuestieDB.QueryObjectSingle(objectIds[1], "name")
        local spawns = QuestieDB.QueryObjectSingle(objectIds[1], "spawns")
        if type(spawns) == "table" then
            local bestZoneId, bestSpawn = pickPreferredSpawn(spawns, getPreferredZoneId(questId))
            if bestZoneId then
                return name, getZoneName(bestZoneId), bestSpawn, bestZoneId
            end
        end
        return name, nil, nil, nil
    end

    return nil, nil, nil, nil
end

-- Turn-in targets are static DB data like start info; cached per questId for the session.
local function getQuestFinishInfo(questId)
    local cached = sessionCache.finishInfo[questId]
    if cached then
        return cached.npcName, cached.zoneName, cached.spawn, cached.areaId
    end
    local npcName, zoneName, spawn, areaId = computeQuestFinishInfo(questId)
    sessionCache.finishInfo[questId] = { npcName = npcName, zoneName = zoneName, spawn = spawn, areaId = areaId }
    return npcName, zoneName, spawn, areaId
end

-- Quest passes when its effective level sits in [player - below, player + above].
local function isLevelInBand(questLevel, playerLevel, below, above)
    if not questLevel or questLevel <= 0 then
        return true
    end
    if (playerLevel - questLevel) > below then
        return false
    end
    if (questLevel - playerLevel) > above then
        return false
    end
    return true
end

-- True when the quest would render red on the player (5+ levels above, QuestieLib's red tier). The custom band never lists red quests, and no mode counts their XP.
local function isQuestRedForPlayer(questLevel, playerLevel)
    if not questLevel or questLevel <= 0 then
        return false
    end
    return (questLevel - playerLevel) >= 5
end

-- The bounds Questie's own available-quest pins use, from its Quest Level Options (AvailableQuests._CalculateAndDrawAvailableQuests): the green range below the player by default, a set offset below, or two set levels. The top is the player's level unless two set levels are chosen.
local function getQuestieLevelBounds(playerLevel)
    local profile = Questie.db.profile
    local style = profile.lowLevelStyle
    if style == Questie.LOWLEVEL_RANGE then
        return profile.minLevelFilter, profile.maxLevelFilter, style
    end
    if style == Questie.LOWLEVEL_OFFSET then
        return playerLevel - profile.manualLevelOffset, playerLevel, style
    end
    return playerLevel - QuestieCompat.GetQuestGreenRange("player"), playerLevel, style
end

-- The quest-level half of AvailableQuests.IsLevelRequirementsFulfilled. Up to the top, every style but "show all low level quests" drops quests under the bottom; above it only two set levels drop the quest, the other styles leave it to the required-level gate.
local function isInQuestieRange(questLevel, playerLevel)
    if not questLevel or questLevel <= 0 then
        return true
    end
    local minLevel, maxLevel, style = getQuestieLevelBounds(playerLevel)
    if questLevel <= maxLevel then
        return style == Questie.LOWLEVEL_ALL or questLevel >= minLevel
    end
    return style ~= Questie.LOWLEVEL_RANGE
end

-- Single authority for the player's level band, shared by display, XP and routing: the custom below / above band minus red quests, or Questie's own level range when that radio is on. The saved band sizes stay clamped by loadSavedVariables and the menu.
local function passesPlayerBand(level, playerLevel)
    if QuestieGuideDB.useQuestieLevelRange then
        return isInQuestieRange(level, playerLevel)
    end
    return isLevelInBand(level, playerLevel, QuestieGuideDB.levelBelow, QuestieGuideDB.levelAbove)
        and not isQuestRedForPlayer(level, playerLevel)
end

-- True when the quest's level keeps it out of the discovery sections entirely. The custom band drops quests Questie colours grey; Questie's own range drops whatever it would not pin, so its "show all low level quests" style lists grey quests too.
local function isLevelExcluded(level, playerLevel)
    if QuestieGuideDB.useQuestieLevelRange then
        return not isInQuestieRange(level, playerLevel)
    end
    if not level or level <= 0 then
        return false
    end
    return QuestieDB.IsTrivial(level)
end

-- True when the quest's XP joins the totals, trip XP and zone rating: green, yellow or orange for the player, in both modes. Grey and red rows still list where the range allows them, but a trip should only be rated by quests worth doing now.
local function countsTowardXp(level, playerLevel)
    if not level or level <= 0 then
        return true
    end
    return not QuestieDB.IsTrivial(level) and not isQuestRedForPlayer(level, playerLevel)
end

-- Highest required level a listed quest may have: the player's level, or the top of Questie's own range, which only its two-set-levels style can lift above the player (the end of AvailableQuests.IsLevelRequirementsFulfilled).
local function getRequiredLevelCap(playerLevel)
    if not QuestieGuideDB.useQuestieLevelRange then
        return playerLevel
    end
    local _, maxLevel = getQuestieLevelBounds(playerLevel)
    return maxLevel
end

-- Questie's two exceptions ahead of its level test (the start of AvailableQuests.IsLevelRequirementsFulfilled), only under its range. A quest whose parent quest is in the log is always in range. Outside the two-set-levels style, so is an active event quest whose required level sits under the bottom, while the player hasn't outlevelled it. The event lookup runs first because the parent query costs a database read.
local function isQuestieRangeException(questId, requiredLevel, requiredMaxLevel, playerLevel)
    if not QuestieGuideDB.useQuestieLevelRange then
        return false
    end
    if QuestieEvent.activeQuests[questId] then
        local minLevel, _, style = getQuestieLevelBounds(playerLevel)
        if style ~= Questie.LOWLEVEL_RANGE and minLevel > requiredLevel
            and (requiredMaxLevel == 0 or playerLevel < requiredMaxLevel) then
            return true
        end
    end
    local parentId = QuestieDB.QueryQuestSingle(questId, "parentQuest")
    return parentId ~= nil and QuestiePlayer.currentQuestlog[parentId] ~= nil
end

-- QuestieDB.IsDoable does not enforce requiredLevel, so we gate it explicitly.
local function meetsRequiredLevel(requiredLevel, playerLevel)
    if not requiredLevel or requiredLevel <= 0 then
        return true
    end
    return requiredLevel <= playerLevel
end

-- Mirrors AvailableQuests.IsLevelRequirementsFulfilled: a quest carrying a requiredMaxLevel is permanently unobtainable once the player outlevels it. IsDoable does not check this either.
local function exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel)
    if not requiredMaxLevel or requiredMaxLevel == 0 then
        return false
    end
    return playerLevel > requiredMaxLevel
end

-- The faction test reads the player's own faction, as _AddStarter does.
local function isNpcStarterReachable(npcId, playerFaction)
    local friendlyToFaction = QuestieDB.QueryNPCSingle(npcId, "friendlyToFaction")
    local hostile = (playerFaction == "Alliance" and friendlyToFaction == "H")
        or (playerFaction == "Horde" and friendlyToFaction == "A")
    if hostile then
        return false
    end
    local spawns = QuestieDB.QueryNPCSingle(npcId, "spawns")
    if type(spawns) == "table" and next(spawns) then
        return true
    end
    local waypoints = QuestieDB.QueryNPCSingle(npcId, "waypoints")
    return type(waypoints) == "table" and next(waypoints) ~= nil
end

local function computeReachableStarter(questId)
    local startedBy = QuestieDB.QueryQuestSingle(questId, "startedBy")
    if type(startedBy) ~= "table" then
        return false
    end
    local playerFaction = UnitFactionGroup("player")
    for _, npcId in ipairs(type(startedBy[1]) == "table" and startedBy[1] or {}) do
        if isNpcStarterReachable(npcId, playerFaction) then
            return true
        end
    end
    for _, objectId in ipairs(type(startedBy[2]) == "table" and startedBy[2] or {}) do
        local spawns = QuestieDB.QueryObjectSingle(objectId, "spawns")
        if type(spawns) == "table" and next(spawns) then
            return true
        end
    end
    return type(startedBy[3]) == "table" and startedBy[3][1] ~= nil
end

-- Mirrors _AddStarter in Questie's AvailableQuests module: a quest only gets a map icon when at least one approachable starter exists. NPC givers hostile to the player's faction are unreachable, and NPC or object givers need at least one spawn or waypoint in the world. Item-started quests count as reachable because Questie draws them at their drop sources. Anything failing this can never be picked up, so it must not be listed or counted. Reachability is static per character (DB plus faction), so results cache for the session.
local function hasReachableStarter(questId)
    local cached = sessionCache.reachable[questId]
    if cached == nil then
        cached = computeReachableStarter(questId)
        sessionCache.reachable[questId] = cached
    end
    return cached
end

-- True when the quest is not gated by the player's race or class.
local function matchesPlayerFaction(questId)
    local requiredRaces = QuestieDB.QueryQuestSingle(questId, "requiredRaces")
    if requiredRaces and not QuestiePlayer.HasRequiredRace(requiredRaces) then
        return false
    end
    local requiredClasses = QuestieDB.QueryQuestSingle(questId, "requiredClasses")
    if requiredClasses and not QuestiePlayer.HasRequiredClass(requiredClasses) then
        return false
    end
    return true
end

-- Returns the active prereq table for a quest along with which type it is. preQuestSingle (OR) takes precedence over preQuestGroup (AND); Questie treats them as exclusive.
local function getQuestPrereqs(questId)
    local preIds = QuestieDB.QueryQuestSingle(questId, "preQuestSingle")
    if type(preIds) == "table" and preIds[1] then
        return preIds, "single"
    end
    preIds = QuestieDB.QueryQuestSingle(questId, "preQuestGroup")
    if type(preIds) == "table" and preIds[1] then
        return preIds, "group"
    end
    return nil, nil
end

-- True when the quest has prereqs and Questie reports them as not yet satisfied.
local function isBlockedByPrereqs(questId)
    local preIds, kind = getQuestPrereqs(questId)
    if not preIds then
        return false
    end
    if kind == "single" then
        return not QuestieDB:IsPreQuestSingleFulfilled(preIds)
    end
    return not QuestieDB:IsPreQuestGroupFulfilled(preIds)
end

-- Returns a list of chains [initial, ..., target] of incomplete prereqs. preQuestSingle (OR) takes the first incomplete alternative; preQuestGroup (AND) branches into one chain per incomplete prereq so the player sees every initial they have to pick up, not just one arbitrary path.
local function findMissingChains(targetId)
    local results = {}

    local function walk(questId, chain, depth, visited)
        if depth > MAX_CHAIN_DEPTH then
            results[#results + 1] = chain
            return
        end
        if not isBlockedByPrereqs(questId) then
            results[#results + 1] = chain
            return
        end
        local preIds, kind = getQuestPrereqs(questId)
        if not preIds then
            results[#results + 1] = chain
            return
        end
        local pending = {}
        for _, preId in ipairs(preIds) do
            if not visited[preId] and not isQuestCompleted(preId) then
                pending[#pending + 1] = preId
            end
        end
        if #pending == 0 then
            results[#results + 1] = chain
            return
        end

        -- OR: any one prereq satisfies the gate, so the first incomplete option is enough. AND: every prereq must be done, so each becomes its own chain.
        if kind == "single" then
            pending = { pending[1] }
        end
        for _, preId in ipairs(pending) do
            local subChain = { preId }
            for _, c in ipairs(chain) do subChain[#subChain + 1] = c end

            -- Clone visited per branch so AND siblings don't shadow each other's nodes.
            local nextVisited = {}
            for k in pairs(visited) do nextVisited[k] = true end
            nextVisited[preId] = true
            walk(preId, subChain, depth + 1, nextVisited)
        end
    end

    walk(targetId, { targetId }, 0, { [targetId] = true })

    local valid = {}
    for _, p in ipairs(results) do
        if #p > 1 then valid[#valid + 1] = p end
    end
    return valid
end

-- Mirrors IsDoable's permanent-exclusion tail, for the follow-up projection and the Missing Pre-Quest rows. exclusiveTo: mutually exclusive alternatives contribute XP once; when the lockout partner is completed, in the log or already counted, this quest is gone (between two exclusive followers the first one found is kept, an acceptable approximation of "count one branch"). nextQuestInChain, breadcrumb targets and availableUntilCompleted follow IsDoable exactly: once that quest is done (or, for the first two, in the log) this one can never be accepted again. Profession, reputation and spell gates are deliberately not mirrored; they are rare on leveling chains and mostly caught by the level gates.
local function isPermanentlyLocked(questId, counted, currentLog)
    local exclusiveTo = QuestieDB.QueryQuestSingle(questId, "exclusiveTo")
    if type(exclusiveTo) == "table" then
        for _, exId in ipairs(exclusiveTo) do
            if counted[exId] or currentLog[exId] or isQuestCompleted(exId) then
                return true
            end
        end
    end
    local nextInChain = QuestieDB.QueryQuestSingle(questId, "nextQuestInChain")
    if nextInChain and nextInChain ~= 0 and (currentLog[nextInChain] or isQuestCompleted(nextInChain)) then
        return true
    end
    local breadcrumbFor = QuestieDB.QueryQuestSingle(questId, "breadcrumbForQuestId")
    if breadcrumbFor and breadcrumbFor ~= 0 and (currentLog[breadcrumbFor] or isQuestCompleted(breadcrumbFor)) then
        return true
    end
    local retiredBy = QuestieDB.QueryQuestSingle(questId, "availableUntilCompleted")
    return retiredBy ~= nil and retiredBy ~= 0 and isQuestCompleted(retiredBy)
end

-- Zone name and area id the player is standing in, per Questie's area mapping; nil when unresolved.
-- ZoneDB:GetAreaIdByUiMapId raises on a map it has no area for, so an unmapped zone must not break every render.
local function getCurrentZoneName()
    local ok, areaId = pcall(QuestiePlayer.GetCurrentZoneId, QuestiePlayer)
    if not ok or not areaId or areaId <= 0 then
        return nil
    end
    return getZoneName(areaId), areaId
end

ns.OTHER_ZONE_NAME = OTHER_ZONE_NAME
ns.sessionCache = sessionCache
ns.isQuestCompleted = isQuestCompleted
ns.getQuestTag = getQuestTag
ns.getQuestXp = getQuestXp
ns.getZoneName = getZoneName
ns.isQuestHidden = isQuestHidden
ns.getEffectiveLevel = getEffectiveLevel
ns.passesLevelCap = passesLevelCap
ns.getQuestName = getQuestName
ns.getQuestStartInfo = getQuestStartInfo
ns.resolveStartInfo = resolveStartInfo
ns.getQuestFinishInfo = getQuestFinishInfo
ns.passesPlayerBand = passesPlayerBand
ns.isLevelExcluded = isLevelExcluded
ns.countsTowardXp = countsTowardXp
ns.getRequiredLevelCap = getRequiredLevelCap
ns.isQuestieRangeException = isQuestieRangeException
ns.meetsRequiredLevel = meetsRequiredLevel
ns.exceedsRequiredMaxLevel = exceedsRequiredMaxLevel
ns.hasReachableStarter = hasReachableStarter
ns.matchesPlayerFaction = matchesPlayerFaction
ns.isBlockedByPrereqs = isBlockedByPrereqs
ns.findMissingChains = findMissingChains
ns.isPermanentlyLocked = isPermanentlyLocked
ns.getCurrentZoneName = getCurrentZoneName
