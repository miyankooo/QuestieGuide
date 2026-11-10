-- Quest data from QuestieDB and the player's quest state from the game: quest facts, givers and turn-ins, XP, zones, the level band, reachability, prerequisites and availability.
local _, ns = ...

local MAX_CHAIN_DEPTH = ns.MAX_CHAIN_DEPTH
local HIDDEN_QUESTS = ns.HIDDEN_QUESTS

-- QuestieDB's entity readers. Core.lua leaves ns.questDB nil when QuestieDB failed its check, and then no launcher opens the window, so nothing here is called.
local questDB = ns.questDB
local Quest = questDB and questDB.Quest
local Npc = questDB and questDB.Npc
local Object = questDB and questDB.Object
local Item = questDB and questDB.Item

local function questField(questId, key)
    return Quest.Get(questId, key)
end

local function itemField(itemId, key)
    return Item.Get(itemId, key)
end

-- Every quest QuestieDB knows, as a shared read-only list.
local function getAllQuestIds()
    return Quest.GetAllIds()
end

local function isRepeatable(questId)
    local flags = questField(questId, "specialFlags")
    return type(flags) == "number" and flags % 2 == 1
end

-- The quests in the player's log, questId -> true. The log's index API skips quests under collapsed headers (Blizzard's QuestSearcher expands them first, QuestMapFrame.lua), so the set is seeded by asking the game about every QuestieDB quest, then follows the accept, remove and turn-in events Events.lua passes on. Read-only for callers.
local questLog

local function getQuestLog()
    if not questLog then
        questLog = {}
        for _, questId in ipairs(getAllQuestIds()) do
            if C_QuestLog.IsOnQuest(questId) then
                questLog[questId] = true
            end
        end
    end
    return questLog
end

-- The game's completed quests, questId -> true. Repeatable quests never enter it.
local completedQuests

local function isQuestCompleted(questId)
    if not completedQuests then
        completedQuests = {}
        for _, completedId in ipairs(C_QuestLog.GetAllCompletedQuestIDs()) do
            completedQuests[completedId] = true
        end
    end
    return completedQuests[questId] == true
end

local function onQuestAccepted(questId)
    if questLog then
        questLog[questId] = true
    end
end

local function onQuestRemoved(questId)
    if questLog then
        questLog[questId] = nil
    end
end

local function onQuestTurnedIn(questId)
    onQuestRemoved(questId)
    if completedQuests and not isRepeatable(questId) then
        completedQuests[questId] = true
    end
end

-- Every loading screen rebuilds both sets on their next read, so an event missed while loading can't stick.
local function resetPlayerQuests()
    questLog, completedQuests = nil, nil
end

-- Ready to turn in: the game says so, or every objective row is done. A quest whose rows have not loaded counts only when QuestieDB lists no objectives for it, like a talk-to quest.
local function isReadyToTurnIn(questId)
    if C_QuestLog.IsComplete(questId) then
        return true
    end
    local rows = C_QuestLog.GetQuestObjectives(questId)
    if type(rows) == "table" and #rows > 0 then
        for _, row in ipairs(rows) do
            if type(row) ~= "table" or not row.finished then
                return false
            end
        end
        return true
    end
    local objectives = questField(questId, "objectives")
    return not (type(objectives) == "table" and next(objectives) ~= nil)
end

-- A quest's tag id and elite flag, the way Forever's quest log shows them: one tag after the name and a "+" after the level (Camelot QuestUtilsOverrides). The client loads a quest it hasn't seen a moment after the first lookup, so callers read the tag at render, never from the scan.
local function getQuestTag(questId)
    local info = C_QuestLog.GetQuestTagInfo(questId)
    return info and info.tagID, C_QuestLog.IsEliteQuest(questId)
end

-- QuestieDB's reward table: questId -> { quest level, base XP }.
local xpSupport = questDB and questDB.Support.Get("QuestXP")
local xpTable = type(xpSupport) == "table" and type(xpSupport.db) == "table" and xpSupport.db or {}

-- The game's quest XP for the player's level: the base XP scaled by the level gap, from 10% to 100%, and rounded in the game's steps. Temporary XP buffs are left out.
local function getQuestXp(questId)
    local entry = xpTable[questId]
    local level, xp = type(entry) == "table" and entry[1], type(entry) == "table" and entry[2]
    if type(level) ~= "number" or type(xp) ~= "number" or level <= 0 or xp <= 0 then
        return 0
    end
    local share = math.min(math.max(2 * (level - UnitLevel("player")) + 20, 1), 10)
    xp = xp * share / 10
    if xp <= 100 then
        return 5 * math.floor((xp + 2) / 5)
    elseif xp <= 500 then
        return 10 * math.floor((xp + 5) / 10)
    elseif xp <= 1000 then
        return 25 * math.floor((xp + 12) / 25)
    end
    return 50 * math.floor((xp + 25) / 50)
end

-- QuestieDB's zone tables: the dungeon list and the maps between area ids and UI map ids.
local zoneSupport = questDB and questDB.Support.Get("ZoneDB")
local zonePrivate = type(zoneSupport) == "table" and type(zoneSupport.private) == "table" and zoneSupport.private or {}

-- QuestieDB ships each zone map as Lua source plus an override map. Each runs once in an empty environment, so it can only build its table.
local function decodeZoneMap(source)
    if type(source) ~= "string" then
        return {}
    end
    local chunk = loadstring(source)
    if not chunk then
        return {}
    end
    setfenv(chunk, {})
    local ok, map = pcall(chunk)
    return ok and type(map) == "table" and map or {}
end

local function mergedZoneMap(name)
    local map = decodeZoneMap(zonePrivate[name])
    for key, value in pairs(decodeZoneMap(zonePrivate[name .. "Override"])) do
        map[key] = value
    end
    return map
end

local zoneMaps

local function getZoneMaps()
    if not zoneMaps then
        zoneMaps = { areaToUiMap = mergedZoneMap("areaIdToUiMapId"), uiMapToArea = mergedZoneMap("uiMapIdToAreaId") }
    end
    return zoneMaps
end

local function getUiMapId(areaId)
    return getZoneMaps().areaToUiMap[areaId]
end

-- The catch-all bucket for quests whose zoneOrSort is a sort category rather than a real area id. Pinned to the bottom of the list by sortZones because it's mostly noise (class quests, faction quests, profession quests, ...).
local OTHER_ZONE_NAME = "Other"

-- zoneOrSort > 0 is a Blizzard area ID; <= 0 is a sort category we collapse into "Other". Names are static client data, and the scan plus the chain projection resolve them for thousands of quests per rescan, so results cache for the session.
local zoneNameCache = {}

-- The client's area name first, then QuestieDB's dungeon list.
local function getZoneName(zoneOrSort)
    if not zoneOrSort or zoneOrSort <= 0 then
        return OTHER_ZONE_NAME
    end
    local cached = zoneNameCache[zoneOrSort]
    if cached then
        return cached
    end
    local dungeon = type(zonePrivate.dungeons) == "table" and zonePrivate.dungeons[zoneOrSort]
    local name = C_Map.GetAreaInfo(zoneOrSort) or (type(dungeon) == "table" and dungeon[1]) or ("Zone " .. zoneOrSort)
    zoneNameCache[zoneOrSort] = name
    return name
end

-- Area name -> area id over every area QuestieDB maps, built on first use. A subzone can share its zone's name; the zone has the lower id and wins.
local areaIdsByName

local function getAreaIdByName(name)
    if not areaIdsByName then
        areaIdsByName = {}
        for areaId in pairs(getZoneMaps().areaToUiMap) do
            local areaName = C_Map.GetAreaInfo(areaId)
            if areaName and (not areaIdsByName[areaName] or areaId < areaIdsByName[areaName]) then
                areaIdsByName[areaName] = areaId
            end
        end
    end
    return name and areaIdsByName[name]
end

-- The area the player stands in. A cave or dungeon entrance without a map of its own reports the continent, so the zone text names the zone there; inside an instance the instance id maps to its area.
local function getCurrentAreaId()
    local uiMapId = C_Map.GetBestMapForUnit("player")
    if not uiMapId then
        local instanceAreas = type(zoneSupport) == "table" and zoneSupport.instanceIdToAreaId
        return type(instanceAreas) == "table" and instanceAreas[select(8, GetInstanceInfo())] or nil
    end
    local mapInfo = C_Map.GetMapInfo(uiMapId)
    if mapInfo and mapInfo.mapType <= Enum.UIMapType.Continent then
        local areaId = getAreaIdByName(GetRealZoneText())
        if areaId then
            return areaId
        end
    end
    return getZoneMaps().uiMapToArea[uiMapId] or getAreaIdByName(mapInfo and mapInfo.name)
end

-- Zone name and area id the player is standing in; nil when unresolved.
local function getCurrentZoneName()
    local areaId = getCurrentAreaId()
    if not areaId or areaId <= 0 then
        return nil
    end
    return getZoneName(areaId), areaId
end

-- Questie's curated list of quests the game never offers on Forever, plus quests the player can't get by doing other quests first: a profession they don't have or a reputation outside the quest's range. Race and class are matchesPlayerFaction's. Needed wherever quests are classified after isDoable already said no (missing-prereq rows, chain projection), so those paths never resurrect them.
local hasRequiredProfession, meetsReputation

local function isQuestHidden(questId)
    return HIDDEN_QUESTS[questId] == true or not hasRequiredProfession(questId) or not meetsReputation(questId)
end

-- QuestieDB's effective levels: a scaling quest (questLevel -1) takes the player's level, and its required level with it unless that is higher; a quest without its own level falls back to its required level.
local function getEffectiveLevel(questId, playerLevel)
    local level = questField(questId, "questLevel")
    local requiredLevel = questField(questId, "requiredLevel") or 0
    local requiredMaxLevel = questField(questId, "requiredMaxLevel") or 0
    if level == -1 then
        if requiredLevel > playerLevel then
            level = requiredLevel
        else
            level, requiredLevel = playerLevel, playerLevel
        end
    end
    if level and level > 0 then
        return level, requiredLevel, requiredMaxLevel
    end
    return requiredLevel, requiredLevel, requiredMaxLevel
end

-- QuestieDB can carry quests above the level cap; they can never be picked up.
local function passesLevelCap(level, requiredLevel)
    local maxLevel = GetMaxPlayerLevel()
    return level <= maxLevel and requiredLevel <= maxLevel
end

local function getQuestName(questId)
    return questField(questId, "name") or ("Quest " .. questId)
end

-- Session caches over static QuestieDB data, keyed by quest id.
local sessionCache = { startInfo = {}, finishInfo = {}, reachable = {}, followers = nil, itemQuests = nil }

-- QuestieDB stores a spawn without a map position (dungeon interiors) as {-1, -1}; such a spawn still names its zone but must not show coordinates or set a waypoint.
local function getSpawnCoords(spawn)
    local x, y = type(spawn) == "table" and spawn[1], type(spawn) == "table" and spawn[2]
    if type(x) == "number" and type(y) == "number" and x >= 0 and y >= 0 and (x > 0 or y > 0) then
        return spawn
    end
    return nil
end

-- Picks a spawn from QuestieDB's per-zone spawn table: prefer the quest's own zone (zoneOrSort) so the labeled location matches the bucket; fall back to the smallest area id when no spawn lives there (deterministic, but arbitrary). Zone and spawn always come from the same entry.
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
    local questZone = questField(questId, "zoneOrSort")
    return (questZone and questZone > 0) and questZone or nil
end

-- Name, zone name, spawn and area id of an NPC or object, located in the quest's own zone when it spawns there.
local function describeSpawnedForQuest(entity, id, questId)
    local name = entity.Get(id, "name")
    if not name then
        return nil
    end
    local spawns = entity.Get(id, "spawns")
    if type(spawns) ~= "table" then
        return name, nil, nil, nil
    end
    local bestZoneId, bestSpawn = pickPreferredSpawn(spawns, getPreferredZoneId(questId))
    if not bestZoneId then
        return name, nil, nil, nil
    end
    return name, getZoneName(bestZoneId), bestSpawn, bestZoneId
end

-- Returns name, zoneName, {x, y}, areaId for the quest's start source. QuestieDB's `startedBy` is a 3-tuple: [1] NPC ids, [2] object ids, [3] item ids. Object/item start (no NPC giver): use the quest's own zone as a best-effort location and "Quest Item" as the generic giver name.
local function computeQuestStartInfo(questId)
    local startedBy = questField(questId, "startedBy")
    if type(startedBy) ~= "table" then
        return nil, nil, nil, nil
    end

    local npcIds = startedBy[1]
    if type(npcIds) == "table" and npcIds[1] then
        local npcName, zoneName, spawn, areaId = describeSpawnedForQuest(Npc, npcIds[1], questId)
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

-- Returns name, zoneName, {x, y}, areaId for the quest's turn-in target. QuestieDB's `finishedBy` is a 2-tuple: [1] NPC ids, [2] object ids. The turn-in location only exists in QuestieDB's data.
local function computeQuestFinishInfo(questId)
    local finishedBy = questField(questId, "finishedBy")
    if type(finishedBy) ~= "table" then
        return nil, nil, nil, nil
    end

    local npcIds = finishedBy[1]
    if type(npcIds) == "table" and npcIds[1] then
        local npcName, zoneName, spawn, areaId = describeSpawnedForQuest(Npc, npcIds[1], questId)
        if npcName then
            return npcName, zoneName, spawn, areaId
        end
    end

    local objectIds = finishedBy[2]
    if type(objectIds) == "table" and objectIds[1] then
        return describeSpawnedForQuest(Object, objectIds[1], questId)
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

-- A quest's colour by level gap, as Enum.RelativeContentDifficulty, on vanilla's scale: red 5 or more levels above the player, orange 3 to 4 above, yellow down to 2 below, green within the game's trivial range, grey below it.
local function getLevelDifficulty(questLevel, playerLevel)
    local levelDiff = questLevel - playerLevel
    if levelDiff >= 5 then
        return Enum.RelativeContentDifficulty.Impossible
    elseif levelDiff >= 3 then
        return Enum.RelativeContentDifficulty.Difficult
    elseif levelDiff >= -2 then
        return Enum.RelativeContentDifficulty.Fair
    elseif -levelDiff <= C_QuestLog.GetTrivialRange() then
        return Enum.RelativeContentDifficulty.Easy
    end
    return Enum.RelativeContentDifficulty.Trivial
end

-- Grey quests: too low to give real XP.
local function isTrivial(questLevel, playerLevel)
    return getLevelDifficulty(questLevel, playerLevel) == Enum.RelativeContentDifficulty.Trivial
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

-- True when the quest renders red on the player (5+ levels above). The band never lists red quests, and no mode counts their XP.
local function isQuestRedForPlayer(questLevel, playerLevel)
    if not questLevel or questLevel <= 0 then
        return false
    end
    return (questLevel - playerLevel) >= 5
end

-- Single authority for the player's level band, shared by display, XP and routing: the below / above band minus red quests. The saved band sizes stay clamped by loadSavedVariables and the menu.
local function passesPlayerBand(level, playerLevel)
    return isLevelInBand(level, playerLevel, QuestieGuideDB.levelBelow, QuestieGuideDB.levelAbove)
        and not isQuestRedForPlayer(level, playerLevel)
end

-- True when the quest's level keeps it out of the discovery sections entirely: grey quests.
local function isLevelExcluded(level, playerLevel)
    if not level or level <= 0 then
        return false
    end
    return isTrivial(level, playerLevel)
end

-- True when the quest's XP joins the totals, trip XP and zone rating: green, yellow or orange for the player. Grey and red rows still list where the range allows them, but a trip should only be rated by quests worth doing now.
local function countsTowardXp(level, playerLevel)
    if not level or level <= 0 then
        return true
    end
    return not isTrivial(level, playerLevel) and not isQuestRedForPlayer(level, playerLevel)
end

-- isDoable does not enforce requiredLevel, so callers gate it explicitly.
local function meetsRequiredLevel(requiredLevel, playerLevel)
    if not requiredLevel or requiredLevel <= 0 then
        return true
    end
    return requiredLevel <= playerLevel
end

-- A quest carrying a requiredMaxLevel is permanently unobtainable once the player outlevels it. isDoable does not check this either.
local function exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel)
    if not requiredMaxLevel or requiredMaxLevel == 0 then
        return false
    end
    return playerLevel > requiredMaxLevel
end

-- The faction test reads the player's own faction.
local function isNpcStarterReachable(npcId, playerFaction)
    local friendlyToFaction = Npc.Get(npcId, "friendlyToFaction")
    local hostile = (playerFaction == "Alliance" and friendlyToFaction == "H")
        or (playerFaction == "Horde" and friendlyToFaction == "A")
    if hostile then
        return false
    end
    local spawns = Npc.Get(npcId, "spawns")
    if type(spawns) == "table" and next(spawns) then
        return true
    end
    local waypoints = Npc.Get(npcId, "waypoints")
    return type(waypoints) == "table" and next(waypoints) ~= nil
end

local function computeReachableStarter(questId)
    local startedBy = questField(questId, "startedBy")
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
        local spawns = Object.Get(objectId, "spawns")
        if type(spawns) == "table" and next(spawns) then
            return true
        end
    end
    return type(startedBy[3]) == "table" and startedBy[3][1] ~= nil
end

-- A quest is only listed when at least one approachable starter exists. NPC givers hostile to the player's faction are unreachable, and NPC or object givers need at least one spawn or waypoint in the world. Item-started quests count as reachable, since the item drops somewhere. Anything failing this can never be picked up, so it must not be listed or counted. Reachability is static per character (DB plus faction), so results cache for the session.
local function hasReachableStarter(questId)
    local cached = sessionCache.reachable[questId]
    if cached == nil then
        cached = computeReachableStarter(questId)
        sessionCache.reachable[questId] = cached
    end
    return cached
end

-- QuestieDB's race masks set one bit per race id; class masks set bit (classId - 1). Read once, since neither changes in a session.
local playerRaceFlag, playerClassFlag

local function hasFlag(mask, flag)
    return mask % (2 * flag) >= flag
end

-- True when the quest is not gated by the player's race or class. A race QuestieDB has no mask for passes every race gate.
local function matchesPlayerFaction(questId)
    if not playerClassFlag then
        playerRaceFlag = questDB.Enum.raceMaskById[select(3, UnitRace("player"))]
        playerClassFlag = 2 ^ (select(3, UnitClass("player")) - 1)
    end
    local requiredRaces = questField(questId, "requiredRaces")
    if playerRaceFlag and requiredRaces and requiredRaces ~= 0 and not hasFlag(requiredRaces, playerRaceFlag) then
        return false
    end
    local requiredClasses = questField(questId, "requiredClasses")
    return not (requiredClasses and requiredClasses ~= 0 and not hasFlag(requiredClasses, playerClassFlag))
end

-- A profession skill line's rank, nil when the player hasn't learned it.
local function getSkillRank(skillId)
    local info = C_SkillInfo.GetSkillLineInfoByID(skillId)
    return info and info.rank > 0 and info.rank or nil
end

-- requiredSkill is {skillLineId, rank}. Lacking the profession hides the quest; a rank too low only keeps it from being doable yet.
function hasRequiredProfession(questId)
    local requiredSkill = questField(questId, "requiredSkill")
    return type(requiredSkill) ~= "table" or getSkillRank(requiredSkill[1]) ~= nil
end

local function meetsRequiredSkill(questId)
    local requiredSkill = questField(questId, "requiredSkill")
    if type(requiredSkill) ~= "table" then
        return true
    end
    local rank = getSkillRank(requiredSkill[1])
    return rank ~= nil and rank >= (requiredSkill[2] or 0)
end

-- A reputation pair is {factionId, standing}: the minimum is inclusive, the maximum exclusive. A faction the game knows nothing about counts as 0.
local function getStanding(factionId)
    local data = C_Reputation.GetFactionDataByID(factionId)
    return data and data.currentStanding or 0
end

function meetsReputation(questId)
    local minRep = questField(questId, "requiredMinRep")
    if type(minRep) == "table" and getStanding(minRep[1]) < minRep[2] then
        return false
    end
    local maxRep = questField(questId, "requiredMaxRep")
    return not (type(maxRep) == "table" and getStanding(maxRep[1]) >= maxRep[2])
end

-- A positive requiredSpell must be known, a negative one must not be.
local function meetsRequiredSpell(questId)
    local spellId = questField(questId, "requiredSpell")
    if not spellId or spellId == 0 then
        return true
    end
    local known = C_SpellBook.IsSpellKnown(math.abs(spellId))
    return (spellId > 0) == (known == true)
end

-- One of the listed quests completed. Questie's preQuestSingle.
local function isPreQuestSingleFulfilled(preIds)
    for _, preId in ipairs(preIds) do
        if isQuestCompleted(preId) then
            return true
        end
    end
    return false
end

-- Every listed quest completed. A positive id is also met when a quest exclusive to it was completed; a negative id must be completed itself. Questie's preQuestGroup.
local function isPreQuestGroupFulfilled(preIds)
    for _, preId in ipairs(preIds) do
        if preId < 0 then
            if not isQuestCompleted(-preId) then
                return false
            end
        elseif not isQuestCompleted(preId) then
            local substitutes = questField(preId, "exclusiveTo")
            local anySubstitute = false
            for _, exId in ipairs(type(substitutes) == "table" and substitutes or {}) do
                if isQuestCompleted(exId) then
                    anySubstitute = true
                    break
                end
            end
            if not anySubstitute then
                return false
            end
        end
    end
    return true
end

-- Returns the active prereq table for a quest along with which type it is. preQuestSingle (OR) takes precedence over preQuestGroup (AND); QuestieDB treats them as exclusive.
local function getQuestPrereqs(questId)
    local preIds = questField(questId, "preQuestSingle")
    if type(preIds) == "table" and preIds[1] then
        return preIds, "single"
    end
    preIds = questField(questId, "preQuestGroup")
    if type(preIds) == "table" and preIds[1] then
        return preIds, "group"
    end
    return nil, nil
end

-- True when the quest has prereqs that are not yet satisfied.
local function isBlockedByPrereqs(questId)
    local preIds, kind = getQuestPrereqs(questId)
    if not preIds then
        return false
    end
    if kind == "single" then
        return not isPreQuestSingleFulfilled(preIds)
    end
    return not isPreQuestGroupFulfilled(preIds)
end

-- A single linked quest that is completed or in the log; 0 and nil mean none.
local function isTaken(questId, currentLog)
    return questId ~= nil and questId ~= 0 and (currentLog[questId] ~= nil or isQuestCompleted(questId))
end

-- Mirrors IsDoable's permanent-exclusion tail, for the follow-up projection and the Missing Pre-Quest rows. exclusiveTo: mutually exclusive alternatives contribute XP once; when the lockout partner is completed, in the log or already counted, this quest is gone (between two exclusive followers the first one found is kept, an acceptable approximation of "count one branch"). nextQuestInChain, breadcrumb targets and availableUntilCompleted follow isDoable exactly: once that quest is done (or, for the first two, in the log) this one can never be accepted again. Profession, reputation and spell gates are deliberately not mirrored; they are rare on leveling chains and mostly caught by the level gates.
local function isPermanentlyLocked(questId, counted, currentLog)
    local exclusiveTo = questField(questId, "exclusiveTo")
    if type(exclusiveTo) == "table" then
        for _, exId in ipairs(exclusiveTo) do
            if counted[exId] or currentLog[exId] or isQuestCompleted(exId) then
                return true
            end
        end
    end
    if isTaken(questField(questId, "nextQuestInChain"), currentLog) or isTaken(questField(questId, "breadcrumbForQuestId"), currentLog) then
        return true
    end
    local retiredBy = questField(questId, "availableUntilCompleted")
    return retiredBy ~= nil and retiredBy ~= 0 and isQuestCompleted(retiredBy)
end

-- isPermanentlyLocked's counted set when nothing is projected.
local NONE_COUNTED = {}

-- Whether the player can accept the quest now, apart from its level, which callers gate: Questie's IsDoable rules on QuestieDB's fields. Profession specializations, profession ranks and daily rotations are left out; none gate a leveling quest on Forever.
local function isDoable(questId)
    local currentLog = getQuestLog()
    if isQuestCompleted(questId) or HIDDEN_QUESTS[questId] or not matchesPlayerFaction(questId) or isBlockedByPrereqs(questId) then
        return false
    end
    if not (meetsReputation(questId) and meetsRequiredSkill(questId) and meetsRequiredSpell(questId)) then
        return false
    end

    -- A parent quest must be in the log; a disabling quest must not be.
    local parentId = questField(questId, "parentQuest")
    if parentId and parentId ~= 0 and not currentLog[parentId] then
        return false
    end
    local disabledBy = questField(questId, "disabledByQuest")
    if disabledBy and disabledBy ~= 0 and currentLog[disabledBy] then
        return false
    end
    if isPermanentlyLocked(questId, NONE_COUNTED, currentLog) then
        return false
    end

    -- A breadcrumb in the log hides the quest it leads to.
    for _, breadcrumbId in ipairs(questField(questId, "breadcrumbs") or {}) do
        if currentLog[breadcrumbId] then
            return false
        end
    end

    -- availableStartingWith opens the quest once that quest is in the log or done.
    local startsWith = questField(questId, "availableStartingWith")
    return not startsWith or startsWith == 0 or isTaken(startsWith, currentLog)
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

ns.OTHER_ZONE_NAME = OTHER_ZONE_NAME
ns.sessionCache = sessionCache
ns.questField = questField
ns.itemField = itemField
ns.getAllQuestIds = getAllQuestIds
ns.isRepeatable = isRepeatable
ns.getQuestLog = getQuestLog
ns.isQuestCompleted = isQuestCompleted
ns.onQuestAccepted = onQuestAccepted
ns.onQuestRemoved = onQuestRemoved
ns.onQuestTurnedIn = onQuestTurnedIn
ns.resetPlayerQuests = resetPlayerQuests
ns.isReadyToTurnIn = isReadyToTurnIn
ns.getQuestTag = getQuestTag
ns.getQuestXp = getQuestXp
ns.getUiMapId = getUiMapId
ns.getZoneName = getZoneName
ns.getCurrentZoneName = getCurrentZoneName
ns.isQuestHidden = isQuestHidden
ns.getEffectiveLevel = getEffectiveLevel
ns.passesLevelCap = passesLevelCap
ns.getQuestName = getQuestName
ns.getQuestStartInfo = getQuestStartInfo
ns.resolveStartInfo = resolveStartInfo
ns.getQuestFinishInfo = getQuestFinishInfo
ns.getLevelDifficulty = getLevelDifficulty
ns.passesPlayerBand = passesPlayerBand
ns.isLevelExcluded = isLevelExcluded
ns.countsTowardXp = countsTowardXp
ns.meetsRequiredLevel = meetsRequiredLevel
ns.exceedsRequiredMaxLevel = exceedsRequiredMaxLevel
ns.hasReachableStarter = hasReachableStarter
ns.matchesPlayerFaction = matchesPlayerFaction
ns.isBlockedByPrereqs = isBlockedByPrereqs
ns.findMissingChains = findMissingChains
ns.isPermanentlyLocked = isPermanentlyLocked
ns.isDoable = isDoable
