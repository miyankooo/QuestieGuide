-- QuestieGuideSteps: step-by-step zone guide panel. Questie-tracker look, RXP step feel, right-click on the minimap button toggles it. Steps regenerate statelessly from live quest state; no progress is stored. Navigation is delegated to TomTom: the panel routes and lists, TomTom points. Rendering is data-driven: buildRows flattens the trip model into typed rows, layoutRows places them with one spacing scale.
local ADDON_NAME, ns = ...

local QuestieDB, QuestieLib, ZoneDB, QuestiePlayer

-- Imports Questie modules lazily because Questie may finish loading after this file.
local function loadModules()
    if QuestieDB then
        return true
    end
    if not ns.loadQuestie or not ns.loadQuestie() then
        return false
    end
    local loader = _G.QuestieLoader
    if not loader then
        return false
    end
    QuestieDB = loader:ImportModule("QuestieDB")
    QuestieLib = loader:ImportModule("QuestieLib")
    ZoneDB = loader:ImportModule("ZoneDB")
    QuestiePlayer = loader:ImportModule("QuestiePlayer")
    return QuestieDB ~= nil
end

-- Design tokens. Convention: every sizing, spacing and font value is a multiple of GRID (4px), stated directly or derived from tokens that are. Two documented exemptions exist: NATIVE metrics that mirror external art (marked NATIVE) and derived centering insets like ROW_PAD. Colors carry exactly four roles.
local GRID = 4
local FONT = "Fonts\\FRIZQT__.TTF"
local FONT_SIZE = GRID * 3
local ROW_H = GRID * 4    -- title, stats, skip and single text rows all land on this height.
local ROW_PAD = (ROW_H - FONT_SIZE) / 2  -- derived: centers the font in ROW_H, half-steps allowed only here.
local PAD = GRID * 2      -- frame edge to content.
local GAP = GRID * 2      -- vertical rhythm between header controls.
local PANEL_W = 260       -- minimum auto width; both dimensions otherwise mirror the tracker sizing.
local MIN_W = 220         -- manual size floor, shared by the resize bounds and the width clamp.
local MIN_H = 120
local MAX_W = 1000
local MAX_H = 1200
local SIZER_SIZE = GRID * 6  -- corner drag hotspot.
local MENU_MAX_H = 200    -- fixed menu height cap; the native MinimalScrollBar engages past it.
local DROP_H = 26         -- NATIVE: intrinsic WowStyle2 dropdown height, off-grid by Blizzard's art.
local SPAWN_CAP = 80      -- caps spawn candidates per step so kill-heavy zones stay cheap.
local X_SCALE = 1.5       -- map aspect compensation for route distances, mirrors Questie's GetSpawnDistance.
local DONE_CAP = 15
local ZONE_PICK_MAX = 5   -- dropdown lists only the strongest zones.
local NEXT_MAX = 3        -- visits listed under the NOW card before Later folds the rest.
local VISIT_EPS = 4       -- squared map units under which co-located NPC steps merge into one visit.

-- Color roles, exactly four: TEXT primary, MUTED secondary, ACCENT gold emphasis, DONE success. ACCENT_RGB carries the same gold for SetTextColor callers.
local COLOR = {
    TEXT = "|cFFEEEEEE",
    MUTED = "|cFFC0C0C0",
    ACCENT = "|cFFFFD100",
    DONE = "|cFF28FF28",
}
local ACCENT_RGB = { 1, 0.82, 0 }

-- Row layout scale: indent and trailing gap per row type, plus SECTION_GAP above non-leading sections. Sub rows carry no gap of their own; their ROW_PAD insets yield the 4px visual rhythm, steps read at 8px and sections at 16px, one doubling scale on the grid.
local INDENT = { section = 0, step = GRID * 3, sub = GRID * 7 }
local GAP_AFTER = { section = GRID, step = GRID, sub = 0 }
local SECTION_GAP = GRID * 2  -- extra air before a section header that is not the first row.

-- RXP-style icon per step kind, inlined into the line text and matched to the font size so icons never inflate line heights.
local ICON_SIZE = FONT_SIZE
local STEP_ICON = {
    pickup = "|TInterface\\GossipFrame\\AvailableQuestIcon:" .. ICON_SIZE .. "|t ",
    objective = "|TInterface\\GossipFrame\\HealerGossipIcon:" .. ICON_SIZE .. "|t ",
    turnin = "|TInterface\\GossipFrame\\ActiveQuestIcon:" .. ICON_SIZE .. "|t ",
}

local stepsFrame
local linePool = {}
local refreshTimer
local doneLog = {}
local lastStepKeys = {}
local currentStepKey
local lastZoneName
local spawnMemo = {}
local hasObjMemo = {}
local measuredWidth = 0
local currentModel
local skipSet = {}        -- derived per render from the zone's persisted skip stack.
local skipStack = {}      -- live reference into QuestieGuideDB.stepsProgress[zone].skips.
local lastWaypointUid
local lastWaypointKey

local function db()
    return QuestieGuideDB or {}
end

local function fmtNum(n)
    if ns.formatNumber then
        return ns.formatNumber(n or 0)
    end
    return tostring(math.floor((n or 0) + 0.5))
end

-- Persisted per-zone progress: done history, skip stack and the current-step pin survive reloads and zone hopping, so returning to a zone picks the trip back up. Empty entries are pruned at login by the main file.
local function zoneProgress(zoneName)
    if type(QuestieGuideDB.stepsProgress) ~= "table" then
        QuestieGuideDB.stepsProgress = {}
    end
    local prog = QuestieGuideDB.stepsProgress[zoneName]
    if type(prog) ~= "table" then
        prog = {}
        QuestieGuideDB.stepsProgress[zoneName] = prog
    end
    if type(prog.done) ~= "table" then
        prog.done = {}
    end
    if type(prog.skips) ~= "table" then
        prog.skips = {}
    end
    return prog
end

-- Fold states persist so an expanded Later, Hidden or Done section survives a reload.
local function folds()
    if type(QuestieGuideDB.stepsFolds) ~= "table" then
        QuestieGuideDB.stepsFolds = {}
    end
    return QuestieGuideDB.stepsFolds
end

-- Live look mirrored from the Questie tracker profile so both trackers read as one family; fonts stay fixed at FONT_SIZE by design. Values above are the fallbacks when Questie or a key is unavailable.
local look = {
    backdrop = true,
    fader = false,
    border = true,
    color = { 0, 0, 0, 1 },
    widthRatio = 0.2,   -- Questie trackerWidthRatio default; caps auto width.
    heightRatio = 0.5,  -- Questie trackerHeightRatio default; caps height.
}

-- Reads backdrop, fader, border and backdrop color from the tracker settings each render, so tracker option changes carry over on the next refresh.
local function refreshLook()
    local questie = _G.Questie
    local profile = questie and questie.db and questie.db.profile
    if not profile then
        return
    end
    if type(profile.trackerBackdropEnabled) == "boolean" then
        look.backdrop = profile.trackerBackdropEnabled
    end
    if type(profile.trackerBackdropFader) == "boolean" then
        look.fader = profile.trackerBackdropFader
    end
    if type(profile.trackerBorderEnabled) == "boolean" then
        look.border = profile.trackerBorderEnabled
    end
    local c = profile.trackerBackdropColor
    if type(c) == "table" then
        look.color = { c.r or c[1] or 0, c.g or c[2] or 0, c.b or c[3] or 0, c.a or c[4] or 1 }
    end
    look.widthRatio = tonumber(profile.trackerWidthRatio) or look.widthRatio
    look.heightRatio = tonumber(profile.trackerHeightRatio) or look.heightRatio
end

-- Paints backdrop and border scaled by a visibility factor; the factor stays 1 unless the tracker's fader setting is mirrored in.
local function applyBackdrop(factor)
    local c = look.color
    stepsFrame:SetBackdropColor(c[1], c[2], c[3], (look.backdrop and c[4] or 0) * factor)
    stepsFrame:SetBackdropBorderColor(1, 1, 1, (look.border and 1 or 0) * factor)
end

-- Hover fade mirroring the tracker: the sizer always fades in on hover; the backdrop and border join only when the tracker's fader setting is mirrored in. Sizing keeps everything forced visible.
local fadeTicker
local fadeValue = 0
local function startFade()
    if not stepsFrame or fadeTicker then
        return
    end
    fadeTicker = C_Timer.NewTicker(0.02, function()
        local over = stepsFrame:IsMouseOver()
        if over then
            fadeValue = math.min(1, fadeValue + 0.07)
        else
            fadeValue = math.max(0, fadeValue - 0.07)
            if fadeValue == 0 then
                fadeTicker:Cancel()
                fadeTicker = nil
            end
        end
        if stepsFrame.sizer then
            stepsFrame.sizer:SetAlpha(fadeValue)
        end
        if look.fader and not stepsFrame.isSizing then
            applyBackdrop(fadeValue)
        end
    end)
end

local function stepKey(step)
    return step.questId .. "|" .. step.kind
end

local function visitKey(visit)
    local keys = {}
    for i, step in ipairs(visit.steps) do
        keys[i] = stepKey(step)
    end
    return table.concat(keys, "+")
end

local function stripColors(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- Continent resolution feeds the travel-cost weight in zone scoring. mapType falls back to 2 (Continent) where Enum.UIMapType is unavailable.
local CONTINENT_TYPE = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
local continentMemo = {}

-- Walks map parents up to the continent; nil when the chain never reaches one.
local function continentOfMap(uiMapId)
    local current = uiMapId
    for _ = 1, 6 do
        if not current or current == 0 then
            return nil
        end
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(current)
        if not info then
            return nil
        end
        if info.mapType == CONTINENT_TYPE then
            return current
        end
        if not info.parentMapID or info.parentMapID == 0 or info.parentMapID == current then
            return nil
        end
        current = info.parentMapID
    end
    return nil
end

local function zoneContinent(zoneName)
    local memo = continentMemo[zoneName]
    if memo ~= nil then
        return memo or nil
    end
    local areaId = ns.getZoneAreaId and ns.getZoneAreaId(zoneName)
    local uiMapId = areaId and ZoneDB and ZoneDB.GetUiMapIdByAreaId and ZoneDB:GetUiMapIdByAreaId(areaId)
    -- False marks a resolved miss so unresolvable zones never re-walk the map chain.
    local cont = uiMapId and continentOfMap(uiMapId) or false
    continentMemo[zoneName] = cont
    return cont or nil
end

-- Scores zones by one-trip XP weighted by level fit and travel proximity, so the suggestion stops sending players across the world for marginal XP. Returns entries sorted best first with the raw XP kept for labels.
local function rankZones()
    local byZone, zoneOrder = ns.ensureScan()
    local playerLevel = UnitLevel("player")
    local playerMap = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local playerCont = playerMap and continentOfMap(playerMap) or nil
    local currentZone = ns.getCurrentZoneName and ns.getCurrentZoneName()
    local ranked = {}
    for _, zoneName in ipairs(zoneOrder or {}) do
        if zoneName ~= ns.OTHER_ZONE_NAME then
            local stats = byZone[zoneName] and byZone[zoneName].stats
            if stats and (stats.count or 0) > 0 and (stats.xp or 0) > 0 then
                local fit = 1
                if stats.avgLevel then
                    -- Tolerates two levels of drift before decaying, mirroring the band most players quest in.
                    local delta = math.abs(stats.avgLevel - playerLevel)
                    if delta > 2 then
                        fit = 1 / (1 + 0.15 * (delta - 2))
                    end
                end
                local prox, far = 0.9, false
                if zoneName == currentZone then
                    prox = 1.25
                else
                    local cont = zoneContinent(zoneName)
                    if cont and playerCont then
                        far = cont ~= playerCont
                        prox = far and 0.6 or 1
                    end
                end
                ranked[#ranked + 1] = { name = zoneName, xp = stats.xp, score = stats.xp * fit * prox, far = far }
            end
        end
    end
    table.sort(ranked, function(a, b) return a.score > b.score end)
    return ranked
end

local function suggestBestZone()
    local ranked = rankZones()
    return ranked[1] and ranked[1].name or nil
end

-- First ranked zone that is not the finished one, for the trip handoff line.
local function suggestNextZone(excludeZone)
    for _, entry in ipairs(rankZones()) do
        if entry.name ~= excludeZone then
            return entry
        end
    end
    return nil
end

-- Returns the guided zone and whether it follows the live suggestion.
local function selectedZone()
    local zone = db().stepsZone
    if zone then
        return zone, false
    end
    return suggestBestZone(), true
end

-- Top zones by score for the picker. The pinned zone stays listed even outside the top so it can be unpinned.
local function topZones()
    local ranked = rankZones()
    local list = {}
    for i = 1, math.min(ZONE_PICK_MAX, #ranked) do
        list[i] = ranked[i]
    end
    local pinned = db().stepsZone
    if pinned then
        for _, entry in ipairs(list) do
            if entry.name == pinned then
                return list
            end
        end
        for _, entry in ipairs(ranked) do
            if entry.name == pinned then
                list[#list + 1] = entry
                return list
            end
        end
        list[#list + 1] = { name = pinned }
    end
    return list
end

-- Adds spawns from one {[zoneId]={{x,y},...}} table that land in the wanted zone; {-1,-1} dungeon markers resolve to entrances. Entries carry the area id so waypoint targets know their map space.
local function addZoneSpawns(spawnTable, zoneName, out)
    if type(spawnTable) ~= "table" then
        return
    end
    for zoneId, list in pairs(spawnTable) do
        if #out >= SPAWN_CAP then
            return
        end
        if type(list) == "table" then
            local inZone = ns.getZoneName(zoneId) == zoneName
            for _, coords in ipairs(list) do
                if #out >= SPAWN_CAP then
                    return
                end
                local x, y = coords[1], coords[2]
                if x == -1 or y == -1 then
                    local locations = ZoneDB and ZoneDB.GetDungeonLocation and ZoneDB:GetDungeonLocation(zoneId)
                    for _, loc in ipairs(locations or {}) do
                        if ns.getZoneName(loc[1]) == zoneName then
                            out[#out + 1] = { loc[2], loc[3], loc[1] }
                            break
                        end
                    end
                elseif inZone and type(x) == "number" and type(y) == "number" then
                    out[#out + 1] = { x, y, zoneId }
                end
            end
        end
    end
end

local function addNpcSpawns(npcId, zoneName, out)
    if type(npcId) ~= "number" then
        return
    end
    addZoneSpawns(QuestieDB.QueryNPCSingle(npcId, "spawns"), zoneName, out)
end

local function addObjectSpawns(objectId, zoneName, out)
    if type(objectId) ~= "number" then
        return
    end
    addZoneSpawns(QuestieDB.QueryObjectSingle(objectId, "spawns"), zoneName, out)
end

-- Item objectives locate via the item's drop and container sources, matching Questie's own spawn-list builder.
local function addItemSpawns(itemId, zoneName, out)
    if type(itemId) ~= "number" or not QuestieDB.GetItem then
        return
    end
    local ok, item = pcall(function() return QuestieDB:GetItem(itemId) end)
    if not ok or type(item) ~= "table" then
        return
    end
    for _, source in ipairs(item.Sources or {}) do
        if source.Type == "monster" then
            addNpcSpawns(source.Id, zoneName, out)
        elseif source.Type == "object" then
            addObjectSpawns(source.Id, zoneName, out)
        end
    end
end

-- Collects in-zone spawn coords across every unfinished objective. Live-log finished filtering only applies when the live entry count matches the DB unit count; on any mismatch every objective contributes, which errs toward showing a location. Memoized per quest and zone; the memo survives pure re-renders and clears on quest events and zone switches.
local function collectObjectiveSpawns(questId, zoneName)
    local memoKey = questId .. "|" .. zoneName
    local memo = spawnMemo[memoKey]
    if memo then
        return memo
    end
    local out = {}
    local objectives = QuestieDB.QueryQuestSingle(questId, "objectives")
    -- Ordered units mirroring Questie's ObjectiveData order so live log indices can line up: creature, object, item, killcredit, spell. Reputation objectives carry no location and are skipped, which simply disables the finished-filter alignment for such quests.
    local units = {}
    if type(objectives) == "table" then
        for _, entry in ipairs(type(objectives[1]) == "table" and objectives[1] or {}) do
            units[#units + 1] = { kind = "npc", id = entry[1] }
        end
        for _, entry in ipairs(type(objectives[2]) == "table" and objectives[2] or {}) do
            units[#units + 1] = { kind = "object", id = entry[1] }
        end
        for _, entry in ipairs(type(objectives[3]) == "table" and objectives[3] or {}) do
            units[#units + 1] = { kind = "item", id = entry[1] }
        end
        for _, entry in ipairs(type(objectives[5]) == "table" and objectives[5] or {}) do
            units[#units + 1] = { kind = "killcredit", ids = type(entry[1]) == "table" and entry[1] or {} }
        end
        for _, entry in ipairs(type(objectives[6]) == "table" and objectives[6] or {}) do
            units[#units + 1] = { kind = "item", id = entry[3] }
        end
    end
    local triggerEnd = QuestieDB.QueryQuestSingle(questId, "triggerEnd")
    if type(triggerEnd) == "table" and type(triggerEnd[2]) == "table" then
        units[#units + 1] = { kind = "event", spawns = triggerEnd[2] }
    end
    local live = C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questId)
    local aligned = type(live) == "table" and #live == #units
    for i, unit in ipairs(units) do
        local finished = aligned and live[i] and live[i].finished
        if not finished then
            if unit.kind == "npc" then
                addNpcSpawns(unit.id, zoneName, out)
            elseif unit.kind == "object" then
                addObjectSpawns(unit.id, zoneName, out)
            elseif unit.kind == "item" then
                addItemSpawns(unit.id, zoneName, out)
            elseif unit.kind == "killcredit" then
                for _, npcId in ipairs(unit.ids) do
                    addNpcSpawns(npcId, zoneName, out)
                end
            elseif unit.kind == "event" then
                addZoneSpawns(unit.spawns, zoneName, out)
            end
        end
    end
    spawnMemo[memoKey] = out
    return out
end

-- True when the quest has any DB objective or event trigger; quests without either auto-complete and go straight to turn-in. Static DB data, so the memo lives for the session.
local function questHasObjectives(questId)
    local memo = hasObjMemo[questId]
    if memo ~= nil then
        return memo
    end
    local result = false
    local objectives = QuestieDB.QueryQuestSingle(questId, "objectives")
    if type(objectives) == "table" then
        for i = 1, 6 do
            local group = objectives[i]
            if type(group) == "table" and next(group) ~= nil then
                result = true
                break
            end
        end
    end
    if not result then
        local triggerEnd = QuestieDB.QueryQuestSingle(questId, "triggerEnd")
        result = type(triggerEnd) == "table" and triggerEnd[1] ~= nil
    end
    hasObjMemo[questId] = result
    return result
end

-- Live objective text lines for an in-log quest, nil-safe when the log entry is missing.
local function liveObjectiveLines(questId)
    local lines = {}
    local live = C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questId)
    for _, obj in ipairs(type(live) == "table" and live or {}) do
        if obj.text and obj.text ~= "" then
            lines[#lines + 1] = { text = obj.text, done = obj.finished and true or false }
        end
    end
    return lines
end

-- Difficulty-colored "[lvl] Name" via Questie; plain fallback keeps the panel alive on API drift.
local function questLabel(questId)
    if QuestieLib and QuestieLib.GetColoredQuestName then
        local ok, label = pcall(function() return QuestieLib:GetColoredQuestName(questId, true, false) end)
        if ok and type(label) == "string" then
            return label
        end
    end
    return "Quest " .. questId
end

-- State-aware navigation target: giver before pickup, an unfinished objective while working, the finisher when the quest is ready. Opens the map with the pulsing Questie pin and lets openMapAtCoord hand the coordinate to TomTom when it is installed.
local function navigateQuest(questId)
    local inLog = QuestiePlayer and QuestiePlayer.currentQuestlog and QuestiePlayer.currentQuestlog[questId]
    if inLog then
        if not questHasObjectives(questId) or QuestieDB.IsComplete(questId) == 1 then
            local _, _, spawn, areaId = ns.getQuestFinishInfo(questId)
            if spawn and areaId and ns.openMapAtCoord then
                ns.openMapAtCoord(areaId, spawn[1], spawn[2], nil, questId)
                return
            end
        else
            -- Objective search order: the zone the player stands in, the guided zone, then the quest's own zone.
            local candidates = {}
            local function addZone(zoneName)
                if zoneName and zoneName ~= ns.OTHER_ZONE_NAME then
                    for _, existing in ipairs(candidates) do
                        if existing == zoneName then
                            return
                        end
                    end
                    candidates[#candidates + 1] = zoneName
                end
            end
            addZone(ns.getCurrentZoneName and ns.getCurrentZoneName())
            addZone(lastZoneName)
            addZone(ns.getZoneName(QuestieDB.QueryQuestSingle(questId, "zoneOrSort")))
            for _, zoneName in ipairs(candidates) do
                local spawns = collectObjectiveSpawns(questId, zoneName)
                if #spawns > 0 and ns.openMapAtCoord then
                    ns.openMapAtCoord(spawns[1][3], spawns[1][1], spawns[1][2], nil, questId)
                    return
                end
            end
        end
    end
    local _, _, spawn, areaId = ns.getQuestStartInfo(questId)
    if spawn and areaId and ns.openMapAtCoord then
        ns.openMapAtCoord(areaId, spawn[1], spawn[2], nil, questId)
        return
    end
    if ns.openMapForQuest then
        ns.openMapForQuest({ id = questId })
    end
end

-- Builds one ordered chain per quest: pickup while not in log, objectives while incomplete, turn-in at an in-zone finisher. Projected steps anticipate work the player has not accepted yet, so routing can weave an objective between two pickups. A turn-in step is never generated without its objective step ahead of it in the chain, keeping incomplete turn-ins impossible by construction. Turned-in quests contribute nothing. Second return: ready quests whose finisher stands in another zone, so owed XP never vanishes silently.
local function generateSteps(zoneName)
    local byZone = ns.ensureScan()
    local entry = byZone and byZone[zoneName]
    local away = {}
    local hidden = {}
    if not entry then
        return {}, away, hidden
    end
    local outsideZone = db().stepsOutsideZone ~= false
    local hideRepeatable = db().stepsHideRepeatable ~= false
    local hideDungeon = db().stepsHideDungeon ~= false
    local hideElite = db().stepsHideElite ~= false
    -- Repeatables are turn-in loops rather than one-trip steps, so the filter defaults on.
    local function isRepeatable(questId)
        return hideRepeatable and QuestieDB.IsRepeatable and QuestieDB.IsRepeatable(questId) or false
    end
    -- Excludes group content by default because the route is a solo travel path; both toggles live in the browser's Guide settings. Returns the reason label for the HIDDEN fold.
    local function tagReason(questId)
        local tag = ns.getQuestTagLabel and ns.getQuestTagLabel(questId)
        if tag == "Dungeon" and hideDungeon then
            return "dungeon"
        end
        if (tag == "Elite" or tag == "Raid") and hideElite then
            return "elite"
        end
        return nil
    end
    local chains = {}
    local seen = {}
    -- Giver-elsewhere quests sit in two zone buckets, so dedupe by quest id.
    local function considerQuest(q)
        if seen[q.id] or q.blocked then
            return
        end
        seen[q.id] = true
        if ns.isQuestCompleted(q.id) then
            return
        end
        -- Filtered quests surface in the HIDDEN fold with their reason instead of vanishing silently.
        local reason
        if q.outOfRange then
            reason = "level range"
        elseif isRepeatable(q.id) then
            reason = "repeatable"
        else
            reason = tagReason(q.id)
        end
        if reason then
            hidden[#hidden + 1] = { questId = q.id, label = questLabel(q.id), reason = reason }
            return
        end
        local questId = q.id
        local label = questLabel(questId)
        local chain = {}
        local hasObjectives = questHasObjectives(questId)
        local ready = q.inLog and (not hasObjectives or QuestieDB.IsComplete(questId) == 1)
        if not q.inLog then
            local npcName, giverZone, spawn, giverArea = ns.getQuestStartInfo(questId)
            if giverZone == zoneName and spawn then
                chain[#chain + 1] = {
                    kind = "pickup", questId = questId, level = q.level, label = label,
                    npcName = npcName, x = spawn[1], y = spawn[2], areaId = giverArea,
                }
            elseif outsideZone and giverZone and giverZone ~= zoneName then
                -- Detour pickup: giver lives elsewhere, so the step heads the route as an unrouted prelude.
                chain[#chain + 1] = {
                    kind = "pickup", questId = questId, level = q.level, label = label,
                    npcName = npcName, detour = true, detourZone = giverZone,
                }
            else
                -- No reachable pickup: nothing in this zone is actionable for the quest yet.
                return
            end
        end
        if not ready and hasObjectives then
            chain[#chain + 1] = {
                kind = "objective", questId = questId, level = q.level, label = label,
                spawns = collectObjectiveSpawns(questId, zoneName),
                lines = q.inLog and liveObjectiveLines(questId) or nil,
                inLog = q.inLog and true or nil,
            }
        end
        local npcName, finishZone, spawn, finishArea = ns.getQuestFinishInfo(questId)
        if finishZone == zoneName then
            chain[#chain + 1] = {
                kind = "turnin", questId = questId, level = q.level, label = label,
                npcName = npcName, x = spawn and spawn[1], y = spawn and spawn[2], areaId = finishArea,
                xp = q.xp, inLog = ready and true or nil,
            }
        elseif finishZone and finishZone ~= zoneName and ready then
            -- Ready but finished elsewhere: listed separately so the owed XP stays visible instead of dropping out of the route.
            away[#away + 1] = {
                kind = "turnin", questId = questId, label = label, npcName = npcName,
                x = spawn and spawn[1], y = spawn and spawn[2], areaId = finishArea,
                awayZone = finishZone, xp = q.xp,
            }
        end
        if #chain > 0 then
            chains[#chains + 1] = chain
        end
    end
    for _, q in ipairs(entry.available or {}) do
        considerQuest(q)
    end
    for _, q in ipairs(entry.pickedUpElsewhere or {}) do
        considerQuest(q)
    end
    -- Sweep the log for turn-in-ready quests set in other zones, because the finisher can stand in the guided zone even when the quest buckets elsewhere. The player's level band gates these too, so no out-of-band quest is ever routed.
    if QuestiePlayer and QuestiePlayer.currentQuestlog then
        local playerLevel = UnitLevel("player")
        for questId in pairs(QuestiePlayer.currentQuestlog) do
            if not seen[questId] and not ns.isQuestCompleted(questId) and not isRepeatable(questId)
                and ns.passesPlayerBand(ns.getEffectiveLevel(questId, playerLevel), playerLevel)
                and (not questHasObjectives(questId) or QuestieDB.IsComplete(questId) == 1) then
                local npcName, finishZone, spawn, finishArea = ns.getQuestFinishInfo(questId)
                if finishZone == zoneName then
                    seen[questId] = true
                    chains[#chains + 1] = { {
                        kind = "turnin", questId = questId, label = questLabel(questId),
                        npcName = npcName, x = spawn and spawn[1], y = spawn and spawn[2], areaId = finishArea,
                        xp = ns.getQuestXp and ns.getQuestXp(questId) or 0,
                        inLog = true,
                    } }
                end
            end
        end
    end
    return chains, away, hidden
end

-- Squared distance with the 1.5 x-scale compensating map aspect, matching Questie.
local function coordDistance(x1, y1, x2, y2)
    local dx = (x1 - x2) * X_SCALE
    local dy = y1 - y2
    return dx * dx + dy * dy
end

-- Distance from the route point to a step: min over objective spawns so the route heads for the nearest instance of the objective, never a centroid in dead space. Returns nil for coordless steps.
local function stepDistance(step, x, y)
    if step.spawns and #step.spawns > 0 then
        local best, bestSpawn
        for _, spawn in ipairs(step.spawns) do
            local d = coordDistance(spawn[1], spawn[2], x, y)
            if not best or d < best then
                best, bestSpawn = d, spawn
            end
        end
        return best, bestSpawn[1], bestSpawn[2], bestSpawn[3]
    end
    if step.x and step.y then
        return coordDistance(step.x, step.y, x, y), step.x, step.y, step.areaId
    end
    return nil
end

-- First usable coordinate of a step, for seeds and pins where no route point exists yet.
local function resolveCoord(step)
    if step.spawns and #step.spawns > 0 then
        return step.spawns[1][1], step.spawns[1][2], step.spawns[1][3]
    end
    return step.x, step.y, step.areaId
end

-- Orders steps: detour prelude, precedence-constrained greedy nearest-neighbour over routable steps, coordless tail. Each quest chain (pickup -> objectives -> turn-in) is a precedence line: a step only becomes eligible once its predecessor is placed, so an objective lying between two pickups routes between them, and a turn-in can never route before its objectives. A chain breaks at its first coordless step; that step and its followers keep chain order in the tail. Skipped steps drop straight to the tail and their followers strand there via precedence. The previously current step stays pinned first so the highlight never jumps out from under the player mid-task.
local function routeSteps(chains, zoneName)
    local prelude, routable, tail = {}, {}, {}
    for _, chain in ipairs(chains) do
        local broken = false
        local prevKey
        for _, step in ipairs(chain) do
            if step.detour then
                prelude[#prelude + 1] = step
                prevKey = stepKey(step)
            elseif skipSet[stepKey(step)] then
                -- Skipped: out of routing, but followers still wait on this key and strand into the tail with it.
                step.skipped = true
                tail[#tail + 1] = step
                prevKey = stepKey(step)
            elseif not broken and resolveCoord(step) then
                step.after = prevKey
                routable[#routable + 1] = step
                prevKey = stepKey(step)
            else
                broken = true
                tail[#tail + 1] = step
            end
        end
    end
    -- Prelude steps count as placed: their in-zone followers are eligible from the route start.
    local placed = {}
    for _, step in ipairs(prelude) do
        placed[stepKey(step)] = true
    end
    local function eligible(step)
        return not step.after or placed[step.after]
    end
    local ordered = {}
    local function placeStep(index, px, py, pArea)
        local step = table.remove(routable, index)
        step.x, step.y = px, py
        step.areaId = pArea or step.areaId
        placed[stepKey(step)] = true
        ordered[#ordered + 1] = step
        return px, py
    end
    local x, y
    if currentStepKey then
        for i, step in ipairs(routable) do
            if stepKey(step) == currentStepKey and eligible(step) then
                x, y = placeStep(i, resolveCoord(step))
                break
            end
        end
    end
    if not x then
        x, y = ns.getPlayerRouteStart(zoneName)
    end
    if not x and #routable > 0 then
        -- Seed at the lowest-level eligible step when the player stands in another zone.
        local seedIdx
        for i, step in ipairs(routable) do
            if eligible(step) and (not seedIdx or (step.level or 0) < (routable[seedIdx].level or 0)) then
                seedIdx = i
            end
        end
        if seedIdx then
            x, y = placeStep(seedIdx, resolveCoord(routable[seedIdx]))
        end
    end
    while #routable > 0 do
        local bestIdx, bestD, bestX, bestY, bestArea
        for i, step in ipairs(routable) do
            if eligible(step) then
                local d, sx, sy, sArea = stepDistance(step, x, y)
                if d and (not bestD or d < bestD) then
                    bestIdx, bestD, bestX, bestY, bestArea = i, d, sx, sy, sArea
                end
            end
        end
        if not bestIdx then
            break
        end
        x, y = placeStep(bestIdx, bestX, bestY, bestArea)
    end
    -- Anything precedence-stranded joins the tail rather than vanishing.
    for _, step in ipairs(routable) do
        tail[#tail + 1] = step
    end
    currentStepKey = ordered[1] and stepKey(ordered[1]) or nil
    return prelude, ordered, tail
end

-- Merges consecutive routed steps at the same NPC and spot into one visit, so one physical stop renders and routes as one numbered block. Objective steps carry no npcName and never merge.
local function groupVisits(ordered)
    local visits = {}
    for _, step in ipairs(ordered) do
        local last = visits[#visits]
        local near = last and last.x and step.x
            and coordDistance(last.x, last.y, step.x, step.y) <= VISIT_EPS
        if last and near and last.npcName and step.npcName and last.npcName == step.npcName then
            last.steps[#last.steps + 1] = step
        else
            visits[#visits + 1] = { steps = { step }, npcName = step.npcName, x = step.x, y = step.y, areaId = step.areaId }
        end
    end
    return visits
end

-- Diffs step keys against the previous generation and keeps a short history of steps whose quest actually advanced, so zone switches never fake progress. XP rides along so the trip header can total gains.
local function recordDone(steps)
    local newKeys = {}
    for _, step in ipairs(steps) do
        newKeys[stepKey(step)] = true
    end
    for key, step in pairs(lastStepKeys) do
        if not newKeys[key] then
            local questId = step.questId
            local advanced
            if step.kind == "pickup" then
                advanced = (QuestiePlayer and QuestiePlayer.currentQuestlog and QuestiePlayer.currentQuestlog[questId] ~= nil)
                    or ns.isQuestCompleted(questId)
            elseif step.kind == "objective" then
                advanced = QuestieDB.IsComplete(questId) == 1 or ns.isQuestCompleted(questId)
            else
                advanced = ns.isQuestCompleted(questId)
            end
            if advanced then
                doneLog[#doneLog + 1] = { key = key, kind = step.kind, label = step.label, questId = step.questId, xp = step.xp }
                if #doneLog > DONE_CAP then
                    table.remove(doneLog, 1)
                end
            end
        end
    end
    lastStepKeys = {}
    for _, step in ipairs(steps) do
        lastStepKeys[stepKey(step)] = step
    end
end

local renderSteps

-- Refresh throttle mirroring the main panel's 0.5s pattern; no-ops while hidden but always drops the spawn memo because quest state moved.
local function scheduleStepsRefresh()
    spawnMemo = {}
    if not stepsFrame or not stepsFrame:IsShown() then
        return
    end
    if refreshTimer then
        refreshTimer:Cancel()
    end
    refreshTimer = C_Timer.NewTimer(0.5, function()
        refreshTimer = nil
        renderSteps()
    end)
end

-- TomTom plumbing: one auto waypoint follows the NOW stop and its live coordinate. The key includes the coordinate, so the arrow retargets both when the stop advances and when objective progress moves the nearest remaining spawn. Manual TomTom waypoints stay untouched in between.
local function clearWaypoint()
    if lastWaypointUid and type(TomTom) == "table" and TomTom.RemoveWaypoint then
        pcall(function() TomTom:RemoveWaypoint(lastWaypointUid) end)
    end
    lastWaypointUid = nil
    lastWaypointKey = nil
end

local function updateWaypoint(model)
    if type(TomTom) ~= "table" or not TomTom.AddWaypoint or db().stepsAutoWaypoint == false then
        return
    end
    local visit = model and model.visits and model.visits[1]
    local key
    if visit then
        key = visitKey(visit) .. string.format("|%.0f,%.0f", visit.x or 0, visit.y or 0)
    end
    if key == lastWaypointKey then
        return
    end
    clearWaypoint()
    lastWaypointKey = key
    if not visit or not visit.x or not visit.areaId then
        return
    end
    local uiMapId = ZoneDB and ZoneDB.GetUiMapIdByAreaId and ZoneDB:GetUiMapIdByAreaId(visit.areaId)
    if not uiMapId then
        return
    end
    local ok, uid = pcall(function()
        return TomTom:AddWaypoint(uiMapId, visit.x / 100, visit.y / 100, {
            title = stripColors(visit.steps[1].label),
            persistent = false,
            minimap = true,
            world = true,
        })
    end)
    if ok then
        lastWaypointUid = uid
    end
end

-- Pooled line: one Button per rendered row. Left-click navigates the quest by state (giver, objective or finisher) on the map, with TomTom picking the coordinate up when installed; right-click opens the native quest log for in-log quests. Section rows carry their own onClick instead. Hovering shows the native quest log title highlight where a click does something.
local function acquireLine(index)
    local line = linePool[index]
    if line then
        line.step = nil
        line.onClick = nil
        line:Show()
        return line
    end
    line = CreateFrame("Button", nil, stepsFrame.scrollChild)
    line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    line.text = line:CreateFontString(nil, "ARTWORK")
    line.text:SetFont(FONT, FONT_SIZE, "")
    line.text:SetJustifyH("LEFT")
    line.text:SetJustifyV("TOP")
    line.text:SetWordWrap(true)
    -- Inset the text vertically so the hover highlight breathes around it instead of sitting edge to edge.
    line.text:SetPoint("TOPLEFT", line, "TOPLEFT", 0, -ROW_PAD)
    line.text:SetPoint("TOPRIGHT", line, "TOPRIGHT", 0, -ROW_PAD)
    -- HIGHLIGHT-layer textures render only while the button is hovered, the same treatment as the native quest log title rows.
    line.hover = line:CreateTexture(nil, "HIGHLIGHT")
    line.hover:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    line.hover:SetBlendMode("ADD")
    line.hover:SetAllPoints(line)
    line:SetScript("OnEnter", startFade)
    line:SetScript("OnClick", function(self, button)
        if self.onClick then
            self.onClick(button)
            return
        end
        local step = self.step
        if not step or not step.questId then
            return
        end
        if button == "RightButton" then
            local inLog = QuestiePlayer and QuestiePlayer.currentQuestlog and QuestiePlayer.currentQuestlog[step.questId]
            if inLog and ns.openQuestInLog then
                ns.openQuestInLog(step.questId)
            end
            return
        end
        navigateQuest(step.questId)
    end)
    linePool[index] = line
    return line
end

local function hideUnusedLines(fromIndex)
    for i = fromIndex, #linePool do
        linePool[i]:Hide()
    end
end

local function buildStepsFrame()
    if stepsFrame then
        return stepsFrame
    end
    local frame = CreateFrame("Frame", "QuestieGuideStepsFrame", UIParent, "BackdropTemplate")
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetSize(PANEL_W, MIN_H)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    -- Initial paint only; every render re-applies the look mirrored from the Questie tracker settings.
    frame:SetBackdropColor(0, 0, 0, 1)
    frame:SetBackdropBorderColor(1, 1, 1, 1)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    elseif frame.SetMinResize then
        frame:SetMinResize(MIN_W, MIN_H)
        frame:SetMaxResize(MAX_W, MAX_H)
    end
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Save the TOPLEFT form so later height changes keep the title fixed.
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
            QuestieGuideDB.stepsPoint = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = left, y = top }
        end
    end)
    frame:HookScript("OnEnter", startFade)
    -- Hiding drops the auto waypoint so no arrow points anywhere while the guide is closed.
    frame:SetScript("OnHide", clearWaypoint)

    local saved = db().stepsPoint
    if type(saved) == "table" and saved.point then
        frame:SetPoint(saved.point, UIParent, saved.relPoint or saved.point, saved.x or 0, saved.y or 0)
    else
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -80, 0)
    end
    frame:Hide()

    -- Collapsible gold title mirroring the tracker header: click toggles, suffix shows the collapsed state.
    local titleButton = CreateFrame("Button", nil, frame)
    titleButton:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
    titleButton:SetHeight(ROW_H)
    local title = titleButton:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, FONT_SIZE, "")
    title:SetPoint("LEFT", titleButton, "LEFT", 0, 0)
    title:SetTextColor(ACCENT_RGB[1], ACCENT_RGB[2], ACCENT_RGB[3])
    frame.title = title
    frame.titleButton = titleButton
    titleButton:SetScript("OnClick", function()
        QuestieGuideDB.stepsCollapsed = not QuestieGuideDB.stepsCollapsed
        renderSteps()
    end)
    -- The title doubles as the drag handle; the drag threshold keeps plain clicks toggling collapse.
    titleButton:RegisterForDrag("LeftButton")
    titleButton:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    titleButton:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local left, top = frame:GetLeft(), frame:GetTop()
        if left and top then
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
            QuestieGuideDB.stepsPoint = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = left, y = top }
        end
    end)

    -- Zone picker: "Suggested" follows the live best zone; any listed zone pins the guide there. Entries carry one-trip XP and a far marker so the ranking explains itself. The menu rebuilds per open, so the zone list tracks the scan.
    local zoneDropdown = CreateFrame("DropdownButton", "QuestieGuideStepsZone", frame, "WowStyle2DropdownTemplate")
    zoneDropdown:SetPoint("TOPLEFT", titleButton, "BOTTOMLEFT", 0, -GAP)
    zoneDropdown:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
    zoneDropdown:SetupMenu(function(_, rootDescription)
        -- Fixed menu height; the menu system swaps in its own MinimalScrollBar when entries overflow it.
        if rootDescription.SetScrollMode then
            rootDescription:SetScrollMode(MENU_MAX_H)
        end
        -- Bail before touching the scan while Questie's DB is still compiling.
        if not loadModules() then
            rootDescription:CreateTitle("Questie is loading...")
            return
        end
        rootDescription:CreateRadio(
            "Suggested Zone",
            function() return db().stepsZone == nil end,
            function()
                QuestieGuideDB.stepsZone = nil
                renderSteps()
            end)
        for _, zoneEntry in ipairs(topZones()) do
            local label = zoneEntry.name
            if zoneEntry.xp then
                label = label .. "  " .. COLOR.MUTED .. fmtNum(zoneEntry.xp) .. " XP" .. (zoneEntry.far and ", far" or "") .. "|r"
            end
            rootDescription:CreateRadio(
                label,
                function() return db().stepsZone == zoneEntry.name end,
                function()
                    QuestieGuideDB.stepsZone = zoneEntry.name
                    renderSteps()
                end)
        end
    end)
    frame.zoneDropdown = zoneDropdown

    -- Trip stats: one chrome-free row, remaining stops left and XP right, collapsing flat when there is no trip. Guide settings live in the browser's Settings pane, keeping this panel chrome-free.
    local statsRow = CreateFrame("Frame", nil, frame)
    statsRow:SetPoint("TOPLEFT", zoneDropdown, "BOTTOMLEFT", 0, -GAP)
    statsRow:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
    statsRow:SetHeight(0)
    statsRow.left = statsRow:CreateFontString(nil, "OVERLAY")
    statsRow.left:SetFont(FONT, FONT_SIZE, "")
    statsRow.left:SetPoint("LEFT", statsRow, "LEFT", 0, 0)
    statsRow.right = statsRow:CreateFontString(nil, "OVERLAY")
    statsRow.right:SetFont(FONT, FONT_SIZE, "")
    statsRow.right:SetPoint("RIGHT", statsRow, "RIGHT", 0, 0)
    frame.statsRow = statsRow

    local scroll = CreateFrame("ScrollFrame", nil, frame)
    scroll:SetPoint("TOPLEFT", statsRow, "BOTTOMLEFT", 0, -GAP)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)
    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(math.max(1, scroll:GetWidth()), 1)
    scroll:SetScrollChild(scrollChild)
    scroll:HookScript("OnSizeChanged", function(self)
        scrollChild:SetWidth(math.max(1, self:GetWidth()))
    end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local range = math.max(0, scrollChild:GetHeight() - self:GetHeight())
        local target = self:GetVerticalScroll() - delta * ROW_H * 2
        self:SetVerticalScroll(math.max(0, math.min(range, target)))
    end)
    frame.scroll = scroll
    frame.scrollChild = scrollChild

    -- Persistent NOW emphasis: the quest log title highlight stretched behind the whole NOW block, anchored per render.
    local nowGlow = scrollChild:CreateTexture(nil, "BACKGROUND")
    nowGlow:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    nowGlow:SetBlendMode("ADD")
    nowGlow:SetAlpha(0.5)
    nowGlow:Hide()
    frame.nowGlow = nowGlow

    -- Skip rejects the NOW stop for this session; the route reseeds around it on the next render and the stop resurfaces under Later.
    local skipBtn = CreateFrame("Button", nil, scrollChild)
    skipBtn:SetFrameLevel(scrollChild:GetFrameLevel() + 10)
    skipBtn:SetSize(GRID * 10, ROW_H)
    local skipText = skipBtn:CreateFontString(nil, "OVERLAY")
    skipText:SetFont(FONT, FONT_SIZE, "")
    skipText:SetText(COLOR.MUTED .. "Skip|r")
    skipText:SetPoint("RIGHT", skipBtn, "RIGHT", 0, 0)
    skipBtn:SetScript("OnEnter", function()
        startFade()
        skipText:SetText(COLOR.TEXT .. "Skip|r")
    end)
    skipBtn:SetScript("OnLeave", function()
        skipText:SetText(COLOR.MUTED .. "Skip|r")
    end)
    skipBtn:SetScript("OnClick", function()
        local visit = currentModel and currentModel.visits and currentModel.visits[1]
        if not visit then
            return
        end
        local group = {}
        for _, step in ipairs(visit.steps) do
            group[#group + 1] = stepKey(step)
        end
        skipStack[#skipStack + 1] = group
        currentStepKey = nil
        renderSteps()
    end)
    skipBtn:Hide()
    frame.skipBtn = skipBtn

    -- Back pops the most recent skip so the rejected stop returns as the NOW step.
    local backBtn = CreateFrame("Button", nil, scrollChild)
    backBtn:SetFrameLevel(scrollChild:GetFrameLevel() + 10)
    backBtn:SetSize(GRID * 10, ROW_H)
    local backText = backBtn:CreateFontString(nil, "OVERLAY")
    backText:SetFont(FONT, FONT_SIZE, "")
    backText:SetText(COLOR.MUTED .. "Back|r")
    backText:SetPoint("RIGHT", backBtn, "RIGHT", 0, 0)
    backBtn:SetScript("OnEnter", function()
        startFade()
        backText:SetText(COLOR.TEXT .. "Back|r")
    end)
    backBtn:SetScript("OnLeave", function()
        backText:SetText(COLOR.MUTED .. "Back|r")
    end)
    backBtn:SetScript("OnClick", function()
        local group = table.remove(skipStack)
        if not group then
            return
        end
        currentStepKey = group[1]
        renderSteps()
    end)
    backBtn:Hide()
    frame.backBtn = backBtn

    -- Corner sizer mirroring the Questie tracker: three nested tooltip-border diagonals, invisible at rest, fading in on hover. Left-drag resizes with a 0.12s ticker that live-saves the size, re-clamps the anchor and re-flows the content, exactly like TrackerBaseFrame.OnResizeStart. Right-click resets both dimensions to 0 = automatic.
    local sizeTimer
    local function resizeStart(_, button)
        if GameTooltip:IsShown() then
            GameTooltip:Hide()
        end
        if InCombatLockdown and InCombatLockdown() then
            return
        end
        if button == "LeftButton" and not frame.isSizing then
            frame.isSizing = true
            frame:StartSizing("BOTTOMRIGHT")
            sizeTimer = C_Timer.NewTicker(0.12, function()
                QuestieGuideDB.stepsWidth = math.floor(frame:GetWidth())
                QuestieGuideDB.stepsHeight = math.floor(frame:GetHeight())
                -- Clamp the anchor while lines re-wrap, then keep sizing; mirrors Questie's ticker.
                local left, top = frame:GetLeft(), frame:GetTop()
                frame:StopMovingOrSizing()
                if left and top then
                    frame:ClearAllPoints()
                    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
                end
                frame:StartSizing("BOTTOMRIGHT")
                renderSteps()
            end)
        elseif button == "RightButton" then
            QuestieGuideDB.stepsWidth = 0
            QuestieGuideDB.stepsHeight = 0
        end
    end
    local function resizeStop(_, button)
        if button == "RightButton" then
            renderSteps()
            return
        end
        if not frame.isSizing then
            return
        end
        frame.isSizing = nil
        frame:StopMovingOrSizing()
        if sizeTimer then
            sizeTimer:Cancel()
            sizeTimer = nil
        end
        QuestieGuideDB.stepsWidth = math.floor(frame:GetWidth())
        QuestieGuideDB.stepsHeight = math.floor(frame:GetHeight())
        renderSteps()
    end

    local sizer = CreateFrame("Frame", nil, frame)
    sizer:SetPoint("BOTTOMRIGHT", 0, 0)
    sizer:SetSize(SIZER_SIZE, SIZER_SIZE)
    -- Raised above the pooled line buttons, which otherwise swallow its clicks where the list overlaps the corner.
    sizer:SetFrameLevel(frame:GetFrameLevel() + 20)
    sizer:SetAlpha(0)
    sizer:EnableMouse(true)
    sizer:SetScript("OnMouseDown", resizeStart)
    sizer:SetScript("OnMouseUp", resizeStop)
    sizer:SetScript("OnEnter", function(self)
        startFade()
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("Left-drag to resize.", 1, 1, 1)
        GameTooltip:AddLine("Right-click for auto size.", 1, 1, 1)
        GameTooltip:Show()
    end)
    sizer:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    for _, size in ipairs({ 14, 11, 8 }) do
        local diag = sizer:CreateTexture(nil, "BACKGROUND")
        diag:SetSize(size, size)
        diag:SetPoint("BOTTOMRIGHT", -4, 4)
        diag:SetTexture("Interface\\Tooltips\\UI-Tooltip-Border")
        -- NATIVE: sizes, offsets and rotated texcoords copied from Questie's TrackerBaseFrame bottom-anchored sizer.
        local x = 0.1 * size / 17
        diag:SetTexCoord(1 / 32, 0.5 + x, 1 / 32 - x, 0.5, 1 / 32 + x, 0.5, 1 / 32, 0.5 - x)
    end
    frame.sizer = sizer

    -- Header controls wake the mirrored fader so entering the panel over them shows the backdrop and the sizer.
    titleButton:HookScript("OnEnter", startFade)
    zoneDropdown:HookScript("OnEnter", startFade)

    -- Applies the collapsed state to the chrome: gold title with the tracker's +/- suffix, everything else hidden while collapsed.
    frame.applyCollapsed = function()
        local collapsed = db().stepsCollapsed and true or false
        title:SetText("Questie Guide " .. (collapsed and "+" or "-"))
        titleButton:SetWidth(title:GetStringWidth() + GAP)
        zoneDropdown:SetShown(not collapsed)
        statsRow:SetShown(not collapsed)
        scroll:SetShown(not collapsed)
        sizer:SetShown(not collapsed)
        return collapsed
    end

    stepsFrame = frame
    return frame
end

-- Fixed header block height above the scroll area: title, zone dropdown, stats row plus paddings.
local function headerHeight()
    local statsH = (stepsFrame and stepsFrame.statsRow and stepsFrame.statsRow:GetHeight()) or 0
    return PAD + ROW_H + GAP + DROP_H + GAP + statsH + GAP
end

-- Feeds the stats row from the trip model: remaining stops left, XP right, both in the unit the list actually numbers. No bar, no chrome; the numbers are the display.
local function updateStats(model)
    local row = stepsFrame.statsRow
    local stops = (model and model.visits and #model.visits) or 0
    local doneCount = (model and model.doneCount) or 0
    if not model or not model.zoneName or (stops == 0 and doneCount == 0) then
        row:SetHeight(0)
        row.left:SetText("")
        row.right:SetText("")
        return
    end
    row:SetHeight(ROW_H)
    if stops == 0 then
        row.left:SetText(COLOR.DONE .. "Trip complete|r")
        row.right:SetText((model.gainedXp or 0) > 0 and (COLOR.MUTED .. "+" .. fmtNum(model.gainedXp) .. " XP|r") or "")
    else
        row.left:SetText(COLOR.TEXT .. stops .. (stops == 1 and " stop left|r" or " stops left|r"))
        row.right:SetText((model.remainXp or 0) > 0 and (COLOR.MUTED .. fmtNum(model.remainXp) .. " XP left|r") or "")
    end
end

-- Renders one row into the pool, growing y; returns the next free index, y and the line for anchoring. click carries either a step (state navigation on left, quest log on right) or an onClick override for section toggles.
local function placeLine(index, y, text, indent, gap, click)
    local line = acquireLine(index)
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", stepsFrame.scrollChild, "TOPLEFT", indent, -y)
    line:SetPoint("TOPRIGHT", stepsFrame.scrollChild, "TOPRIGHT", 0, -y)
    line.text:SetText(text)
    line.step = click and click.step or nil
    line.onClick = click and click.onClick or nil
    -- Hover highlight only where a click does something.
    line.hover:SetAlpha((line.step or line.onClick) and 1 or 0)
    -- Track the widest unwrapped line so auto width can fit content like the tracker.
    measuredWidth = math.max(measuredWidth, indent + math.ceil(line.text:GetUnboundedStringWidth()))
    local h = math.max(FONT_SIZE, math.ceil(line.text:GetStringHeight())) + ROW_PAD * 2
    line:SetHeight(h)
    return index + 1, y + h + gap, line
end

-- Row builders: each visit flattens to one step row (plus objective sub-rows on the NOW card) or an "At <npc>:" header with one action per sub-row.
local function pushVisit(rows, visit, number, expanded, now)
    local prefix = number and (number .. ". ") or ""
    if #visit.steps > 1 then
        rows[#rows + 1] = { type = "step", text = COLOR.TEXT .. prefix .. "At " .. (visit.npcName or "?") .. ":|r", click = { step = visit.steps[1] }, now = now }
        for _, step in ipairs(visit.steps) do
            rows[#rows + 1] = { type = "sub", text = STEP_ICON[step.kind] .. step.label, click = { step = step }, now = now }
        end
        return
    end
    local step = visit.steps[1]
    rows[#rows + 1] = { type = "step", text = STEP_ICON[step.kind] .. prefix .. step.label, click = { step = step }, now = now }
    if expanded and step.lines then
        for _, lineData in ipairs(step.lines) do
            local color = lineData.done and COLOR.DONE or COLOR.TEXT
            rows[#rows + 1] = { type = "sub", text = color .. lineData.text .. "|r", click = { step = step }, now = now }
        end
    end
end

local function pushStep(rows, step, suffix)
    rows[#rows + 1] = { type = "step", text = STEP_ICON[step.kind] .. step.label .. (suffix or ""), click = { step = step } }
end

-- Flattens the trip model into typed rows: prelude only while out of zone, NOW block, short queue, folded Later and Done, turn-in-elsewhere list and the next-zone handoff. Pure data; layoutRows does all positioning.
local function buildRows(model)
    local rows = {}
    if not model.zoneName then
        rows[#rows + 1] = { type = "step", indent = 0, text = COLOR.TEXT .. "No zone with open quests found.|r" }
        return rows
    end
    local visits = model.visits
    -- Prelude only reads as actionable before travel; mid-route in the zone it is noise above the NOW card.
    if not model.inZone and #model.prelude > 0 then
        rows[#rows + 1] = { type = "section", text = COLOR.ACCENT .. "Before you travel|r" }
        for _, step in ipairs(model.prelude) do
            pushStep(rows, step, step.detourZone and (" " .. COLOR.MUTED .. "(in " .. step.detourZone .. ")|r") or nil)
        end
    end
    if visits[1] then
        rows[#rows + 1] = { type = "section", text = COLOR.ACCENT .. "Next|r", skip = true, now = true }
        pushVisit(rows, visits[1], nil, true, true)
    end
    for i = 2, math.min(#visits, 1 + NEXT_MAX) do
        pushVisit(rows, visits[i], i, false, false)
    end
    -- Later fold: far-queue visits plus coordless, stranded and skipped steps stay reachable without crowding the card.
    local laterStart = 2 + NEXT_MAX
    local laterCount = #model.tail
    for i = laterStart, #visits do
        laterCount = laterCount + #visits[i].steps
    end
    local skippedCount = 0
    for _, step in ipairs(model.tail) do
        if step.skipped then
            skippedCount = skippedCount + 1
        end
    end
    if laterCount > 0 then
        local suffix = skippedCount > 0 and (", " .. skippedCount .. " skipped") or ""
        rows[#rows + 1] = { type = "section", text = COLOR.ACCENT .. (folds().later and "- " or "+ ") .. "Later (" .. laterCount .. suffix .. ")|r", click = { onClick = function()
            folds().later = not folds().later
            renderSteps()
        end } }
        if folds().later then
            for i = laterStart, #visits do
                pushVisit(rows, visits[i], i, false, false)
            end
            for _, step in ipairs(model.tail) do
                pushStep(rows, step, step.skipped and (" " .. COLOR.MUTED .. "(skipped)|r") or nil)
            end
            if skippedCount > 0 then
                rows[#rows + 1] = { type = "step", text = COLOR.MUTED .. "Restore skipped steps|r", click = { onClick = function()
                    for i = #skipStack, 1, -1 do
                        table.remove(skipStack)
                    end
                    renderSteps()
                end } }
            end
        end
    end
    if #model.away > 0 then
        rows[#rows + 1] = { type = "section", text = COLOR.ACCENT .. "Turn in elsewhere|r" }
        for _, step in ipairs(model.away) do
            pushStep(rows, step, " " .. COLOR.MUTED .. "(in " .. step.awayZone .. ")|r")
        end
    end
    -- Filtered quests stay visible behind one fold so the guide never hides work without saying so.
    if model.hidden and #model.hidden > 0 then
        rows[#rows + 1] = { type = "section", text = COLOR.ACCENT .. (folds().hidden and "- " or "+ ") .. "Hidden (" .. #model.hidden .. ")|r", click = { onClick = function()
            folds().hidden = not folds().hidden
            renderSteps()
        end } }
        if folds().hidden then
            for _, h in ipairs(model.hidden) do
                rows[#rows + 1] = { type = "step", text = h.label .. " " .. COLOR.MUTED .. "(" .. h.reason .. ")|r", click = { step = { questId = h.questId } } }
            end
        end
    end
    -- Done folds at the bottom so the past never crowds the next action.
    if model.doneCount > 0 then
        rows[#rows + 1] = { type = "section", text = COLOR.ACCENT .. (folds().done and "- " or "+ ") .. "Done (" .. model.doneCount .. ")|r", click = { onClick = function()
            folds().done = not folds().done
            renderSteps()
        end } }
        if folds().done then
            for _, done in ipairs(doneLog) do
                rows[#rows + 1] = { type = "step", text = STEP_ICON[done.kind] .. done.label .. " " .. COLOR.DONE .. "(Done)|r", click = { step = { questId = done.questId } } }
            end
        end
    end
    -- Handoff closes the loop: the trip ends by offering the next best zone one click away.
    if model.nextZone then
        local nz = model.nextZone
        local xpBit = nz.xp and (" " .. COLOR.MUTED .. "(" .. fmtNum(nz.xp) .. " XP)|r") or ""
        rows[#rows + 1] = { type = "section", text = COLOR.ACCENT .. "Next zone: " .. nz.name .. "|r" .. xpBit, click = { onClick = function()
            QuestieGuideDB.stepsZone = nz.name
            renderSteps()
        end } }
    end
    if #rows == 0 then
        rows[#rows + 1] = { type = "step", indent = 0, text = COLOR.TEXT .. "Nothing to do here. Pick another zone.|r" }
    end
    return rows
end

-- Positions the rows with the one spacing scale: per-type indent and trailing gap, one separator before each non-leading section. Anchors the NOW glow and the Skip button along the way; returns the content height.
local function layoutRows(rows)
    local index, y = 1, 0
    local glowTop, glowBottom
    stepsFrame.skipBtn:Hide()
    stepsFrame.backBtn:Hide()
    stepsFrame.nowGlow:Hide()
    for i, row in ipairs(rows) do
        if row.type == "section" and i > 1 then
            y = y + SECTION_GAP
        elseif row.type == "step" and rows[i - 1] and rows[i - 1].type == "sub" then
            -- Rechunk after a sub block so consecutive visits keep the step rhythm between them.
            y = y + GRID
        end
        local rowTop = y
        local line
        index, y, line = placeLine(index, y, row.text, row.indent or INDENT[row.type], GAP_AFTER[row.type], row.click)
        if row.skip then
            stepsFrame.skipBtn:ClearAllPoints()
            stepsFrame.skipBtn:SetPoint("RIGHT", line, "RIGHT", 0, 0)
            stepsFrame.skipBtn:Show()
            if #skipStack > 0 then
                stepsFrame.backBtn:ClearAllPoints()
                stepsFrame.backBtn:SetPoint("RIGHT", line, "RIGHT", -(GRID * 10), 0)
                stepsFrame.backBtn:Show()
            end
        end
        if row.now then
            glowTop = glowTop or rowTop
            glowBottom = y - GAP_AFTER[row.type]
        end
    end
    if glowTop then
        stepsFrame.nowGlow:ClearAllPoints()
        stepsFrame.nowGlow:SetPoint("TOPLEFT", stepsFrame.scrollChild, "TOPLEFT", 0, -math.max(0, glowTop - ROW_PAD))
        stepsFrame.nowGlow:SetPoint("BOTTOMRIGHT", stepsFrame.scrollChild, "TOPRIGHT", 0, -(glowBottom + ROW_PAD))
        stepsFrame.nowGlow:Show()
    end
    hideUnusedLines(index)
    return y
end

-- Regenerates the full trip model from live state: chains, done diff, route, visits, progress totals and the next-zone handoff. Zone switches reset history, pin, skips and the spawn memo because they belong to the previous route.
local function buildModel()
    local zoneName, suggested = selectedZone()
    if zoneName ~= lastZoneName then
        -- Zone switch: reset the diff baseline and memo, then load the new zone's persisted progress instead of wiping it.
        lastZoneName = zoneName
        lastStepKeys = {}
        spawnMemo = {}
        if zoneName then
            local prog = zoneProgress(zoneName)
            doneLog = prog.done
            skipStack = prog.skips
            currentStepKey = prog.current
        else
            doneLog, skipStack, currentStepKey = {}, {}, nil
        end
    end
    skipSet = {}
    for _, group in ipairs(skipStack) do
        for _, key in ipairs(group) do
            skipSet[key] = true
        end
    end
    local model = { zoneName = zoneName, suggested = suggested }
    if not zoneName then
        return model
    end
    local chains, away, hidden = generateSteps(zoneName)
    local flatSteps = {}
    for _, chain in ipairs(chains) do
        for _, step in ipairs(chain) do
            flatSteps[#flatSteps + 1] = step
        end
    end
    -- Away turn-ins join the diff so completing one elsewhere still lands in the done history with its XP.
    for _, step in ipairs(away) do
        flatSteps[#flatSteps + 1] = step
    end
    recordDone(flatSteps)
    local prelude, ordered, tail = routeSteps(chains, zoneName)
    zoneProgress(zoneName).current = currentStepKey
    model.prelude = prelude
    model.hidden = hidden
    model.visits = groupVisits(ordered)
    model.tail = tail
    model.away = away
    model.inZone = (ns.getCurrentZoneName and ns.getCurrentZoneName() == zoneName) or false
    model.doneCount = #doneLog
    local gained, remain = 0, 0
    for _, done in ipairs(doneLog) do
        if done.kind == "turnin" then
            gained = gained + (done.xp or 0)
        end
    end
    local function tallyRemain(steps)
        for _, step in ipairs(steps) do
            if step.kind == "turnin" then
                remain = remain + (step.xp or 0)
            end
        end
    end
    tallyRemain(ordered)
    tallyRemain(tail)
    tallyRemain(away)
    model.gainedXp = gained
    model.remainXp = remain
    if #model.visits == 0 then
        model.nextZone = suggestNextZone(zoneName)
    end
    return model
end

-- Lays the model out: stats row, then the flattened rows, then the tracker-style auto sizing. reflow re-lays the same rows once after an auto width change so wraps settle, no regeneration.
local function layoutModel(model, reflow)
    measuredWidth = 0
    updateStats(model)
    local y = layoutRows(buildRows(model))
    stepsFrame.scrollChild:SetHeight(y)
    if not stepsFrame.isSizing then
        -- Width mirrors the tracker's UpdateWidth: a manual value overrides, auto fits the widest line capped by the width ratio.
        local manualW = db().stepsWidth or 0
        local target
        if manualW > 0 then
            target = math.max(MIN_W, manualW)
        else
            target = math.max(PANEL_W, math.min(measuredWidth + PAD * 2, UIParent:GetWidth() * look.widthRatio))
        end
        if not reflow and math.abs(stepsFrame:GetWidth() - target) > 1 then
            stepsFrame:SetWidth(target)
            stepsFrame.scrollChild:SetWidth(math.max(1, target - PAD * 2))
            return layoutModel(model, true)
        end
        -- Height mirrors the tracker's UpdateHeight: content height, clamped down by the manual height or the height ratio; the list scrolls past the clamp.
        local content = headerHeight() + y + PAD
        local manualH = db().stepsHeight or 0
        local heightCheck = math.max(manualH > 0 and manualH or (UIParent:GetHeight() * look.heightRatio), MIN_H)
        stepsFrame:SetHeight(content > heightCheck and heightCheck or math.max(content, MIN_H))
    end
end

-- Full stateless re-render: regenerate the model, lay it out, then retarget the auto waypoint. Generation runs once per render; width reflows reuse the model.
renderSteps = function()
    if not stepsFrame or not stepsFrame:IsShown() then
        return
    end
    refreshLook()
    if stepsFrame.isSizing then
        -- Sizing: chrome forced visible so the bounds are seen, mirroring the tracker's resize ticker; the drag owns the frame size and anchor.
        local c = look.color
        stepsFrame:SetBackdropColor(c[1], c[2], c[3], c[4])
        stepsFrame:SetBackdropBorderColor(1, 1, 1, 1)
    else
        applyBackdrop(look.fader and fadeValue or 1)
        -- The title is the anchor: normalize to TOPLEFT so collapse and resize grow downward from it, like the tracker.
        local left, top = stepsFrame:GetLeft(), stepsFrame:GetTop()
        if left and top then
            stepsFrame:ClearAllPoints()
            stepsFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        end
    end
    -- Collapsed: only the gold title row remains, mirroring the tracker's minimized state; the frame shrink-wraps it so backdrop and border hug "Questie Guide +".
    if stepsFrame.applyCollapsed() then
        hideUnusedLines(1)
        stepsFrame.skipBtn:Hide()
        stepsFrame.backBtn:Hide()
        stepsFrame.nowGlow:Hide()
        stepsFrame:SetWidth(stepsFrame.titleButton:GetWidth() + PAD * 2)
        stepsFrame:SetHeight(PAD * 2 + ROW_H)
        return
    end
    if not loadModules() then
        measuredWidth = 0
        stepsFrame.skipBtn:Hide()
        stepsFrame.backBtn:Hide()
        stepsFrame.nowGlow:Hide()
        updateStats(nil)
        local index, y = placeLine(1, 0, COLOR.TEXT .. "Questie is loading...|r", 0, GAP_AFTER.step)
        hideUnusedLines(index)
        stepsFrame.scrollChild:SetHeight(y)
        stepsFrame.zoneDropdown:OverrideText("Loading...")
        -- Poll until Questie.started flips; quest events may all fire before the DB is ready.
        if not stepsFrame.loadRetry then
            stepsFrame.loadRetry = true
            C_Timer.After(1, function()
                stepsFrame.loadRetry = nil
                if stepsFrame:IsShown() then
                    renderSteps()
                end
            end)
        end
        return
    end
    local model = buildModel()
    currentModel = model
    local zoneName, suggested = model.zoneName, model.suggested
    stepsFrame.zoneDropdown:OverrideText(zoneName and (suggested and ("Suggested: " .. zoneName) or zoneName) or "No zone suggested")
    layoutModel(model, false)
    updateWaypoint(model)
end

local function toggleStepsPanel()
    local frame = buildStepsFrame()
    if frame:IsShown() then
        frame:Hide()
        QuestieGuideDB.stepsShown = false
    else
        frame:Show()
        QuestieGuideDB.stepsShown = true
        -- Defer the first paint one tick so the scroll child's width resolves before text heights are measured.
        C_Timer.After(0, function()
            if frame:IsShown() then
                renderSteps()
            end
        end)
    end
end
ns.toggleStepsPanel = toggleStepsPanel

-- Main-panel Guide checkbox calls this so both views stay in sync.
ns.refreshStepsPanel = function()
    if stepsFrame and stepsFrame:IsShown() then
        renderSteps()
    end
end

-- Own event frame: the main file already invalidates the scan on the same events in the same tick, so ensureScan is always fresh by the time the throttle fires. QUEST_WATCH_UPDATE keeps the NOW card and the auto waypoint current with objective progress.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("QUEST_ACCEPTED")
loader:RegisterEvent("QUEST_REMOVED")
loader:RegisterEvent("QUEST_TURNED_IN")
loader:RegisterEvent("PLAYER_LEVEL_UP")
loader:RegisterEvent("ZONE_CHANGED_NEW_AREA")
loader:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
loader:RegisterEvent("QUEST_WATCH_UPDATE")
loader:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        -- Restore the panel when it was open last session; the loading placeholder covers Questie still initializing.
        if QuestieGuideDB and QuestieGuideDB.stepsShown then
            local frame = buildStepsFrame()
            frame:Show()
            C_Timer.After(1, renderSteps)
        end
    elseif event == "UNIT_QUEST_LOG_CHANGED" then
        if arg1 == "player" then
            scheduleStepsRefresh()
        end
    else
        scheduleStepsRefresh()
    end
end)
