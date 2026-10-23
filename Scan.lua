-- The zone scan: every listable quest bucketed by zone with its trip XP, the follow-up projection, the zone sort and the completed section.
local _, ns = ...

local MAX_CHAIN_DEPTH = ns.MAX_CHAIN_DEPTH
local OTHER_ZONE_NAME = ns.OTHER_ZONE_NAME
local SUBCAT_ORDER = ns.SUBCAT_ORDER
local sessionCache = ns.sessionCache
local isQuestCompleted = ns.isQuestCompleted
local getQuestXp = ns.getQuestXp
local getZoneName = ns.getZoneName
local isQuestHidden = ns.isQuestHidden
local getEffectiveLevel = ns.getEffectiveLevel
local passesLevelCap = ns.passesLevelCap
local getQuestName = ns.getQuestName
local getQuestStartInfo = ns.getQuestStartInfo
local getQuestFinishInfo = ns.getQuestFinishInfo
local passesPlayerBand = ns.passesPlayerBand
local isLevelExcluded = ns.isLevelExcluded
local countsTowardXp = ns.countsTowardXp
local getRequiredLevelCap = ns.getRequiredLevelCap
local isQuestieRangeException = ns.isQuestieRangeException
local meetsRequiredLevel = ns.meetsRequiredLevel
local exceedsRequiredMaxLevel = ns.exceedsRequiredMaxLevel
local hasReachableStarter = ns.hasReachableStarter
local matchesPlayerFaction = ns.matchesPlayerFaction
local isBlockedByPrereqs = ns.isBlockedByPrereqs
local findMissingChains = ns.findMissingChains
local isPermanentlyLocked = ns.isPermanentlyLocked

local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")

-- Reverse prereq index: preQuestId -> { followerQuestId, ... }. Built once per session because the quest DB is static; only completion state changes at runtime. Negative preQuestGroup ids are indexed by absolute value so those followers stay discoverable through that edge.
local function ensureFollowerIndex()
    if sessionCache.followers then
        return sessionCache.followers
    end
    local followerIndex = {}
    sessionCache.followers = followerIndex
    local function addEdge(preId, questId)
        if type(preId) == "number" and preId ~= 0 then
            if preId < 0 then preId = -preId end
            local list = followerIndex[preId]
            if not list then
                list = {}
                followerIndex[preId] = list
            end
            list[#list + 1] = questId
        end
    end
    for questId in pairs(QuestieDB.QuestPointers) do
        local preIds = QuestieDB.QueryQuestSingle(questId, "preQuestSingle")
        if type(preIds) == "table" then
            for _, preId in ipairs(preIds) do addEdge(preId, questId) end
        end
        preIds = QuestieDB.QueryQuestSingle(questId, "preQuestGroup")
        if type(preIds) == "table" then
            for _, preId in ipairs(preIds) do addEdge(preId, questId) end
        end
        local parentId = QuestieDB.QueryQuestSingle(questId, "parentQuest")
        if parentId and parentId ~= 0 then
            addEdge(parentId, questId)
        end
    end
    return followerIndex
end

-- A prereq is settled for the follow-up projection when it is already completed or part of the counted set (a quest the player can pick up now or unlocks along the way).
local function isPreSettled(preId, counted)
    return counted[preId] == true or isQuestCompleted(preId)
end

-- Mirrors QuestieDB:IsPreQuestSingleFulfilled / IsPreQuestGroupFulfilled with counted treated as "will be completed". Single: any one entry settled. Group: every entry settled, where negative ids must be settled directly and positive ids may substitute via a settled exclusiveTo alternative. parentQuest children need the parent active, so the parent must be in the counted set rather than merely completed.
local function prereqsSettled(questId, counted)
    local single = QuestieDB.QueryQuestSingle(questId, "preQuestSingle")
    if type(single) == "table" and single[1] then
        local anySettled = false
        for _, preId in ipairs(single) do
            if isPreSettled(preId, counted) then
                anySettled = true
                break
            end
        end
        if not anySettled then
            return false
        end
    end
    local group = QuestieDB.QueryQuestSingle(questId, "preQuestGroup")
    if type(group) == "table" and group[1] then
        for _, preId in ipairs(group) do
            if preId < 0 then
                if not isPreSettled(-preId, counted) then
                    return false
                end
            elseif not isPreSettled(preId, counted) then
                local substitutes = QuestieDB.QueryQuestSingle(preId, "exclusiveTo")
                local anySubstitute = false
                if type(substitutes) == "table" then
                    for _, exId in ipairs(substitutes) do
                        if isPreSettled(exId, counted) then
                            anySubstitute = true
                            break
                        end
                    end
                end
                if not anySubstitute then
                    return false
                end
            end
        end
    end
    local parentId = QuestieDB.QueryQuestSingle(questId, "parentQuest")
    if parentId and parentId ~= 0 and not counted[parentId] then
        return false
    end
    return true
end

-- Projects which not-yet-doable quests unlock inside the zone once its seed quests are done, without leaving the zone. BFS over the reverse prereq index: a follower joins when it is set in the zone or starts at a giver in the zone, passes the same level and faction gates as the discovery scan, and every prereq is completed or already part of the projection. Accepted followers re-enter the frontier so deep chains resolve, and an AND-gated follower is re-examined via the edge from whichever prereq settles last. requiredLevel is deliberately not gated: the player levels up while clearing the zone, and the level band already bounds how far ahead the projection reaches. Repeatables are skipped, they are turn-in loops rather than one-trip chain XP.
local function collectZoneFollowups(zoneName, seeds, currentLog, playerLevel, isFollowerInRange)
    local index = ensureFollowerIndex()
    local counted = {}
    local frontier = {}
    for _, questId in ipairs(seeds) do
        counted[questId] = true
        frontier[#frontier + 1] = questId
    end
    local ids = {}
    local xpTotal, count = 0, 0
    for _ = 1, MAX_CHAIN_DEPTH do
        local nextFrontier = {}
        for _, questId in ipairs(frontier) do
            for _, followerId in ipairs(index[questId] or {}) do
                if not counted[followerId]
                    and not currentLog[followerId]
                    and not isQuestCompleted(followerId) then
                    -- Zone membership: set in the zone (zoneOrSort) or picked up in the zone (giver). The cheap zoneOrSort check runs first; the giver lookup is session-cached per quest.
                    local zoneOrSort = QuestieDB.QueryQuestSingle(followerId, "zoneOrSort")
                    local inZone = zoneOrSort and getZoneName(zoneOrSort) == zoneName
                    if not inZone then
                        local _, giverZoneName = getQuestStartInfo(followerId)
                        inZone = giverZoneName == zoneName
                    end
                    if inZone then
                        local level, requiredLevel, requiredMaxLevel = getEffectiveLevel(followerId, playerLevel)
                        if passesLevelCap(level, requiredLevel)
                            and not exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel)
                            and isFollowerInRange(followerId, level, requiredLevel, requiredMaxLevel)
                            and not isQuestHidden(followerId)
                            and hasReachableStarter(followerId)
                            and matchesPlayerFaction(followerId)
                            and not QuestieDB.IsRepeatable(followerId)
                            and not isPermanentlyLocked(followerId, counted, currentLog)
                            and prereqsSettled(followerId, counted) then
                            counted[followerId] = true
                            nextFrontier[#nextFrontier + 1] = followerId
                            ids[followerId] = true

                            -- Grey and red followers stay in the projection so their own followers and the blocked rows still resolve, but add no XP.
                            if countsTowardXp(level, playerLevel) then
                                xpTotal = xpTotal + getQuestXp(followerId)
                                count = count + 1
                            end
                        end
                    end
                end
            end
        end
        if #nextFrontier == 0 then
            break
        end
        frontier = nextFrontier
    end
    return { xp = xpTotal, count = count, ids = ids }
end

-- Buckets every quest into its zone. Expensive; caller should cache the result.
local function scanQuestsByZone()
    local playerLevel = UnitLevel("player")
    local currentLog = QuestiePlayer.currentQuestlog
    local requiredCap = getRequiredLevelCap(playerLevel)

    -- The active level range for one quest: the custom band, or Questie's range plus its two exceptions. Failing quests are flagged outOfRange; only in-log rows still render then, and none add XP.
    local function passesLevelGate(questId, level, requiredLevel, requiredMaxLevel)
        return passesPlayerBand(level, playerLevel)
            or isQuestieRangeException(questId, requiredLevel, requiredMaxLevel, playerLevel)
    end

    -- The discovery sections' hard level gates, the required-level cap and isLevelExcluded; Questie's exceptions waive them too, as its early returns skip its whole test.
    local function passesListingGates(questId, level, requiredLevel, requiredMaxLevel)
        return (meetsRequiredLevel(requiredLevel, requiredCap) and not isLevelExcluded(level, playerLevel))
            or isQuestieRangeException(questId, requiredLevel, requiredMaxLevel, playerLevel)
    end

    -- Follow-ups skip the required-level gate by design (see collectZoneFollowups), so only the band and isLevelExcluded apply, again waived by Questie's exceptions.
    local function isFollowerInRange(questId, level, requiredLevel, requiredMaxLevel)
        return (passesPlayerBand(level, playerLevel) and not isLevelExcluded(level, playerLevel))
            or isQuestieRangeException(questId, requiredLevel, requiredMaxLevel, playerLevel)
    end

    local byZone = {}

    -- A Missing Pre-Quest row only lists while the quest can still unlock; nothing is projected as counted here.
    local NONE_COUNTED = {}

    local function ensureZone(zoneName)
        local entry = byZone[zoneName]
        if not entry then
            entry = {
                available = {},
                pickedUpElsewhere = {},
            }
            byZone[zoneName] = entry
        end
        return entry
    end

    -- Quests already in the player's log obey the level band like everything else: out-of-band log quests hide from the list, XP and routing, surfacing only under an active search. They render inside the pickup buckets with an [In Questlog] label, split by giver zone like every other quest.
    for questId in pairs(currentLog) do
        local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
        local level, requiredLevel, requiredMaxLevel = getEffectiveLevel(questId, playerLevel)
        if zoneOrSort and passesLevelCap(level, requiredLevel) then
            local questZoneName = getZoneName(zoneOrSort)
            local _, giverZoneName = getQuestStartInfo(questId)
            local quest = {
                id = questId,
                level = level,
                name = getQuestName(questId),

                -- Questie's QuestXP already applies the level reduction; grey and red log quests still list but add none of it to the totals.
                xp = getQuestXp(questId),
                countsXp = countsTowardXp(level, playerLevel),
                repeatable = QuestieDB.IsRepeatable(questId),
                inLog = true,
                outOfRange = not passesLevelGate(questId, level, requiredLevel, requiredMaxLevel),
            }
            local entry = ensureZone(questZoneName)
            local giverElsewhere = giverZoneName and giverZoneName ~= questZoneName
            local bucket = giverElsewhere and entry.pickedUpElsewhere or entry.available
            bucket[#bucket + 1] = quest
            if giverElsewhere then
                local giverEntry = ensureZone(giverZoneName)
                giverEntry.available[#giverEntry.available + 1] = quest
            end
        end
    end

    for questId in pairs(QuestieDB.QuestPointers) do
        if not currentLog[questId] and not isQuestCompleted(questId) then
            local level, requiredLevel, requiredMaxLevel = getEffectiveLevel(questId, playerLevel)

            -- Out-of-range quests stay in the list, tagged so renderList can hide or fade their rows; only the level cap, the required-level gates, isLevelExcluded (grey quests, or quests outside Questie's own range), and quests without a reachable starter exclude quests entirely from the discovery sections.
            if passesLevelCap(level, requiredLevel)
                and not exceedsRequiredMaxLevel(requiredMaxLevel, playerLevel)
                and passesListingGates(questId, level, requiredLevel, requiredMaxLevel)
                and hasReachableStarter(questId) then
                local outOfRange = not passesLevelGate(questId, level, requiredLevel, requiredMaxLevel)

                -- Only Questie's two-set-levels style lets a required level above the player's through. Questie pins those quests with its grey "!" (QuestieLib.GetQuestIcon); they list with a Requires Level label and never add XP.
                local canAccept = meetsRequiredLevel(requiredLevel, playerLevel)
                if QuestieDB.IsDoable(questId) then
                    local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
                    if zoneOrSort then
                        local questZoneName = getZoneName(zoneOrSort)
                        local _, giverZoneName = getQuestStartInfo(questId)
                        local entry = ensureZone(questZoneName)
                        local quest = {
                            id = questId,
                            level = level,
                            name = getQuestName(questId),
                            xp = getQuestXp(questId),
                            countsXp = canAccept and countsTowardXp(level, playerLevel),
                            lockedLevel = not canAccept and requiredLevel or nil,
                            repeatable = QuestieDB.IsRepeatable(questId),
                            outOfRange = outOfRange,
                        }

                        -- Non-log quests where the giver NPC lives in another zone go to "Starts Elsewhere" as a navigation hint: the quest is set here but you'd need to go somewhere else to start it. Quests with a giver in this zone (or with no resolvable giver location) stay under "Starts Here".
                        local bucket = (giverZoneName and giverZoneName ~= questZoneName)
                            and entry.pickedUpElsewhere
                            or entry.available
                        bucket[#bucket + 1] = quest

                        -- A quest picked up in this zone but set elsewhere also counts for the giver zone: it lists under "Starts Here" there and joins that zone's XP totals and follow-up seeds. The quest table is shared; its fields are zone-independent.
                        if giverZoneName and giverZoneName ~= questZoneName then
                            local giverEntry = ensureZone(giverZoneName)
                            giverEntry.available[#giverEntry.available + 1] = quest
                        end
                    end
                elseif canAccept and not isQuestHidden(questId) and isBlockedByPrereqs(questId) and matchesPlayerFaction(questId)
                    and not isPermanentlyLocked(questId, NONE_COUNTED, currentLog) then
                    local zoneOrSort = QuestieDB.QueryQuestSingle(questId, "zoneOrSort")
                    if zoneOrSort then
                        -- Pick the shortest prereq chain. We don't require the chain initial to be doable; if it is, its tooltip badge shows `[Available]`, otherwise the chain is informational. Each blocked quest contributes ONE row keyed by its own questId; quests in `available` never reappear here.
                        local bestChain
                        for _, chain in ipairs(findMissingChains(questId)) do
                            if not bestChain or #chain < #bestChain then
                                bestChain = chain
                            end
                        end
                        if bestChain then
                            -- Blocked quests land greyed in the same pickup buckets as doable ones. Each zone gets its own row table because unlocksHere is marked per zone by the follow-up projection.
                            local function addBlockedRow(zoneName, bucketKey)
                                local entry = ensureZone(zoneName)
                                local bucket = entry[bucketKey]
                                bucket[#bucket + 1] = {
                                    id = questId,
                                    level = level,
                                    name = getQuestName(questId),
                                    xp = getQuestXp(questId),
                                    countsXp = countsTowardXp(level, playerLevel),
                                    repeatable = QuestieDB.IsRepeatable(questId),
                                    chain = bestChain,
                                    blocked = true,
                                    outOfRange = outOfRange,
                                }
                            end
                            local questZoneName = getZoneName(zoneOrSort)
                            local _, giverZoneName = getQuestStartInfo(questId)
                            local giverElsewhere = giverZoneName and giverZoneName ~= questZoneName
                            addBlockedRow(questZoneName, giverElsewhere and "pickedUpElsewhere" or "available")

                            -- A blocked quest starting at a giver in another zone also lists there, mirroring the doable path above.
                            if giverElsewhere then
                                addBlockedRow(giverZoneName, "available")
                            end
                        end
                    end
                end
            end
        end
    end

    -- Actionable rows stay at the top of each bucket: in-range doable first, then in-range blocked or level-locked (greyed), then out-of-range, level/name ordered within each tier.
    local function sortQuests(list)
        local function tier(q)
            return (q.outOfRange and 2 or 0) + ((q.blocked or q.lockedLevel) and 1 or 0)
        end
        table.sort(list, function(a, b)
            local ta, tb = tier(a), tier(b)
            if ta ~= tb then
                return ta < tb
            end
            if a.level == b.level then
                return a.name < b.name
            end
            return a.level < b.level
        end)
    end

    local zoneOrder = {}
    for zoneName, entry in pairs(byZone) do
        zoneOrder[#zoneOrder + 1] = zoneName
        sortQuests(entry.available)
        sortQuests(entry.pickedUpElsewhere)

        -- Stats power both the zone header summary and the zone sort. Count only in-range quests so the figures match what a player would consider when choosing where to level; in-log rows obey the band like everything else. The pickable rows double as seeds for the follow-up projection below; blocked rows are tallied after the projection settles which of them unlock in-zone.
        local countInRange = 0
        local xpNow = 0
        local seeds = {}
        local function tallyDoable(list)
            for _, q in ipairs(list) do
                if not q.blocked and not q.outOfRange then
                    countInRange = countInRange + 1
                    if q.countsXp then
                        xpNow = xpNow + (q.xp or 0)
                    end

                    -- A level-locked quest can't be picked up this trip, so nothing it unlocks can be either.
                    if not q.lockedLevel then
                        seeds[#seeds + 1] = q.id
                    end
                end
            end
        end
        tallyDoable(entry.available)
        tallyDoable(entry.pickedUpElsewhere)

        -- Follow-up projection: chains that keep unlocking in this zone (set here or starting here) once the seeds are done. Blocked quests whose chain runs through another zone stay out of the XP total and are reported separately, so a zone is never credited XP that requires traveling elsewhere to unlock.
        entry.followups = collectZoneFollowups(zoneName, seeds, currentLog, playerLevel, isFollowerInRange)
        local travelXp, travelCount = 0, 0
        local function tallyBlocked(list)
            for _, q in ipairs(list) do
                if q.blocked then
                    q.unlocksHere = entry.followups.ids[q.id] == true
                    if not q.outOfRange then
                        countInRange = countInRange + 1
                        if not q.unlocksHere and q.countsXp then
                            travelXp = travelXp + (q.xp or 0)
                            travelCount = travelCount + 1
                        end
                    end
                end
            end
        end
        tallyBlocked(entry.available)
        tallyBlocked(entry.pickedUpElsewhere)

        local levelSum, levelCount = 0, 0
        for _, q in ipairs(entry.available) do
            if not q.blocked and not q.inLog and not q.outOfRange and not q.lockedLevel and q.level and q.level > 0 then
                levelSum = levelSum + q.level
                levelCount = levelCount + 1
            end
        end

        -- xp is the one-trip value: everything grabbable now plus everything that unlocks in-zone along the way, green, yellow and orange quests only (countsTowardXp). It drives the XP sort, the best-zone marker and the Next banner.
        entry.stats = {
            count = countInRange,
            xp = xpNow + entry.followups.xp,
            xpFollowup = entry.followups.xp,
            followupCount = entry.followups.count,
            travelXp = travelXp,
            travelCount = travelCount,
            avgLevel = levelCount > 0 and (levelSum / levelCount) or nil,
        }
    end

    table.sort(zoneOrder)
    return byZone, zoneOrder
end

-- Apply the user's sort mode + direction in place. Cheap; safe to call every render. Zones without a value for the chosen metric sort to the END regardless of direction (so the player sees only zones with available quests at the top).
local function sortZones(zoneOrder, byZone)
    local mode = QuestieGuideDB.sortMode
    local desc = QuestieGuideDB.sortDir == "desc"

    local function compareNumeric(getValue)
        local missing = desc and -math.huge or math.huge
        return function(a, b)
            local va = getValue(a) or missing
            local vb = getValue(b) or missing
            if va == vb then return a < b end
            if desc then return va > vb end
            return va < vb
        end
    end

    if mode == "count" then
        table.sort(zoneOrder, compareNumeric(function(z) return byZone[z].stats.count end))
    elseif mode == "xp" then
        table.sort(zoneOrder, compareNumeric(function(z) return byZone[z].stats.xp end))
    elseif mode == "avgLevel" then
        table.sort(zoneOrder, compareNumeric(function(z) return byZone[z].stats.avgLevel end))
    else
        if desc then
            table.sort(zoneOrder, function(a, b) return a > b end)
        else
            table.sort(zoneOrder)
        end
    end

    -- "Other" holds the sort-category catch-all (class/faction/profession quests with no real zoneOrSort). Pin it to the bottom regardless of the selected mode or direction since it's almost always noise compared to the real zones above it.
    for i, name in ipairs(zoneOrder) do
        if name == OTHER_ZONE_NAME then
            table.remove(zoneOrder, i)
            zoneOrder[#zoneOrder + 1] = name
            break
        end
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

-- Quests in the log that are ready to turn in, bucketed by the turn-in target's zone. Detection uses QuestieDB.IsComplete, which also settles no-objective auto-complete quests; the zone grouping needs Questie's finishedBy data either way. Cheap (the log holds few quests), so it runs fresh every render instead of joining the scan cache.
local function collectCompletedByZone()
    local playerLevel = UnitLevel("player")
    local byZone = {}
    local zoneOrder = {}
    for questId in pairs(QuestiePlayer.currentQuestlog) do
        if QuestieDB.IsComplete(questId) == 1 then
            local npcName, zoneName, spawn, areaId = getQuestFinishInfo(questId)
            local bucketName = zoneName or OTHER_ZONE_NAME
            local quest = {
                id = questId,
                level = getEffectiveLevel(questId, playerLevel),
                name = getQuestName(questId),
                xp = getQuestXp(questId),
                completed = true,

                -- Finisher stands in for startInfo so row line 2, map clicks, and the waypoint all point at the turn-in target instead of the giver.
                startInfo = { npcName = npcName, zoneName = zoneName, spawn = spawn, areaId = areaId },
            }
            local bucket = byZone[bucketName]
            if not bucket then
                bucket = {}
                byZone[bucketName] = bucket
                zoneOrder[#zoneOrder + 1] = bucketName
            end
            bucket[#bucket + 1] = quest
        end
    end
    for _, list in pairs(byZone) do
        table.sort(list, function(a, b)
            if a.level == b.level then
                return a.name < b.name
            end
            return a.level < b.level
        end)
    end

    -- Zones with the most turn-ins first so the best trip reads at a glance; ties alphabetical, "Other" pinned last like the main list.
    table.sort(zoneOrder, function(a, b)
        if a == OTHER_ZONE_NAME then return false end
        if b == OTHER_ZONE_NAME then return true end
        local countA, countB = #byZone[a], #byZone[b]
        if countA ~= countB then
            return countA > countB
        end
        return a < b
    end)
    return byZone, zoneOrder
end

-- The zone with the highest one-trip value (XP available now plus follow-ups unlocking in-zone): the answer to "where should I go questing next", independent of the active sort. "Other" is a sort catch-all rather than a destination, so it never wins.
local function findBestZone(byZone, zoneOrder)
    local bestZoneName, bestXp = nil, 0
    for _, zoneName in ipairs(zoneOrder) do
        local stats = zoneName ~= OTHER_ZONE_NAME and byZone[zoneName].stats
        if stats and stats.xp > bestXp then
            bestZoneName, bestXp = zoneName, stats.xp
        end
    end
    return bestZoneName
end

-- Quests in a zone the player could accept now. It reads a scan that may predate the last accept or turn-in, so it also skips quests that have since entered the log or been completed; a quest abandoned since stays uncounted until the next scan.
local function countPickable(entry)
    local currentLog = QuestiePlayer.currentQuestlog
    local counted, count = {}, 0
    for _, subKey in ipairs(SUBCAT_ORDER) do
        for _, q in ipairs(entry[subKey]) do
            if not (q.inLog or q.blocked or q.outOfRange or q.lockedLevel or counted[q.id])
                and not currentLog[q.id] and not isQuestCompleted(q.id) then
                counted[q.id] = true
                count = count + 1
            end
        end
    end
    return count
end

ns.scanCache = scanCache
ns.invalidateScan = invalidateScan
ns.ensureScan = ensureScan
ns.sortZones = sortZones
ns.collectCompletedByZone = collectCompletedByZone
ns.findBestZone = findBestZone
ns.countPickable = countPickable
