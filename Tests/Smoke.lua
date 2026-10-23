-- Offline smoke test for QuestieGuide. It loads every toc file in order against stubs of the client and
-- of Questie, opens the window, then checks a render, the launcher status, the dungeon line, a combat
-- click, the Filter menu, a level change, a search and the map pins. It proves the files wire together
-- and the list logic runs; how the window looks still needs an in-game pass.
--
-- Run from the QuestieGuide folder:  lua Tests/Smoke.lua

local here = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
local ROOT = here .. "../"
local ADDON_NAME = "QuestieGuide"

local realPrint = print
local failures, passes = 0, 0
local function check(label, ok, detail)
    if ok then
        passes = passes + 1
    else
        failures = failures + 1
        realPrint("FAIL " .. label .. (detail ~= nil and (" (" .. tostring(detail) .. ")") or ""))
    end
end

-- Lua helpers the client adds to the global table.
tinsert = table.insert
strmatch = string.match
function strtrim(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function CopyTable(t)
    local copy = {}
    for k, v in pairs(t) do copy[k] = type(v) == "table" and CopyTable(v) or v end
    return copy
end

-- Timers queue and run when the test flushes them, in the order they were started.
local timers = {}
local function flushTimers()
    local guard = 0
    while #timers > 0 do
        guard = guard + 1
        if guard > 100 then error("timers keep rescheduling") end
        local timer = table.remove(timers, 1)
        if not timer.cancelled then timer.fn() end
    end
end
C_Timer = {
    After = function(_, fn) timers[#timers + 1] = { fn = fn } end,
    NewTimer = function(_, fn)
        local timer = { fn = fn }
        timer.Cancel = function(self) self.cancelled = true end
        timers[#timers + 1] = timer
        return timer
    end,
}

-- Chat goes to a list the checks read.
local chat = {}
print = function(line) chat[#chat + 1] = line end

local function colour(r, g, b)
    return {
        r = r, g = g, b = b,
        GetRGB = function(self) return self.r, self.g, self.b end,
        WrapTextInColorCode = function(_, text) return "|cff" .. text .. "|r" end,
    }
end
function CreateColor(r, g, b) return colour(r, g, b) end
NORMAL_FONT_COLOR = colour(1, 0.82, 0)
HIGHLIGHT_FONT_COLOR = colour(1, 1, 1)
GRAY_FONT_COLOR = colour(0.5, 0.5, 0.5)
GREEN_FONT_COLOR = colour(0.1, 1, 0.1)
RED_FONT_COLOR = colour(1, 0.1, 0.1)
WARNING_FONT_COLOR = colour(1, 0.5, 0)
YELLOW_FONT_COLOR = colour(1, 1, 0)
LIGHTBLUE_FONT_COLOR = colour(0.5, 0.8, 1)
ORANGE_FONT_COLOR = colour(1, 0.5, 0.25)
LINK_FONT_COLOR = colour(0.4, 0.73, 1)
QuestDifficultyColors = { header = colour(0.7, 0.7, 0.7) }

local function font(size) return { GetFont = function() return "Fonts\\FRIZQT__.TTF", size end } end
GameFontNormal = font(12)
GameFontHighlight = font(12)
GameFontDisable = font(12)
GameFontNormalLarge = font(16)

-- Global strings with their enUS values (GlobalStrings/enUS.lua) and constants (LuaEnum.lua).
PARENS_TEMPLATE = "(%s)"
ITEM_MIN_LEVEL = "Requires Level %d"
QUEST_CLASSIFICATION_RECURRING = "Repeatable"
DUNGEONS = "Dungeons"
LEVEL_RANGE = "Level Range"
WHO_SORT_LABEL = "Sort By"
WHO_SORT_ASCENDING_LABEL = "Ascending"
WHO_SORT_DESCENDING_LABEL = "Descending"
ELITE = "Elite"
CALENDAR_TYPE_DUNGEON = "Dungeon"
CALENDAR_TYPE_PVP = "PvP"
RAID = "Raid"
FILTER = "Filter"
Constants = { QuestConsts = { QUEST_INFO_ELITE_ID = 1, QUEST_INFO_DUNGEON_ID = 81, QUEST_INFO_PVP_ID = 41, QUEST_INFO_RAID_ID = 62 } }
Enum = { TooltipDataType = { Item = 0 } }
MenuResponse = { Open = 1, Refresh = 2, Close = 3, CloseAll = 4 }
PANEL_INSET_TOP_OFFSET = -24
PANEL_INSET_ATTIC_OFFSET = -60
SCROLL_FRAME_SCROLL_BAR_OFFSET_LEFT = 6
UISpecialFrames = {}
SlashCmdList = {}

-- Frames that registered an event, in creation order, so the test can fire events at them.
local eventFrames = {}

-- Regions keep their geometry, text and scripts as plain fields, so checks read them directly.
local Region = {}
Region.__index = Region

local function newRegion(kind, name, parent)
    local region = setmetatable({ kind = kind, name = name, parent = parent, points = {}, scripts = {}, hooks = {},
        children = {}, shown = true, width = 0, height = 0 }, Region)
    if parent then parent.children[#parent.children + 1] = region end
    return region
end

local function runScript(region, event, ...)
    if region.scripts[event] then region.scripts[event](region, ...) end
    for _, hook in ipairs(region.hooks[event] or {}) do hook(region, ...) end
end

function Region:SetSize(w, h) self.width, self.height = w, h end
function Region:SetWidth(w) self.width = w end
function Region:SetHeight(h) self.height = h end
function Region:GetWidth() return self.width end
function Region:GetHeight() return self.height end
function Region:ClearAllPoints() self.points = {} end
function Region:SetPoint(point, rel, relPoint, x, y)
    if type(rel) == "number" then rel, relPoint, x, y = nil, nil, rel, relPoint end
    self.points[#self.points + 1] = { point = point, rel = rel, relPoint = relPoint, x = x or 0, y = y or 0 }
end
function Region:GetPoint(i)
    local p = self.points[i]
    return p.point, p.rel, p.relPoint, p.x, p.y
end
function Region:SetAllPoints() end
function Region:Show()
    if self.shown then return end
    self.shown = true
    runScript(self, "OnShow")
end
function Region:Hide() self.shown = false end
function Region:SetShown(shown) if shown then self:Show() else self:Hide() end end
function Region:IsShown() return self.shown end
function Region:IsVisible() return self.shown end
function Region:SetAlpha(alpha) self.alpha = alpha end
function Region:SetScript(event, fn) self.scripts[event] = fn end
function Region:GetScript(event) return self.scripts[event] end
function Region:HookScript(event, fn)
    self.hooks[event] = self.hooks[event] or {}
    table.insert(self.hooks[event], fn)
end
function Region:SetFrameStrata(strata) self.strata = strata end
function Region:SetToplevel() end
function Region:SetClampedToScreen() end
function Region:SetMovable() end
function Region:EnableMouse() end
function Region:RegisterForDrag() end
function Region:RegisterForClicks() end
function Region:RegisterEvent(event)
    if not self.events then
        self.events = {}
        eventFrames[#eventFrames + 1] = self
    end
    self.events[event] = true
end
function Region:SetHitRectInsets() end
function Region:SetAutoFocus() end
function Region:SetScrollChild(child) self.scrollChild = child end
function Region:SetFontObject(fontObject) self.fontObject = fontObject end
function Region:SetJustifyH() end
function Region:SetWordWrap() end
function Region:GetTextColor() return 0.5, 0.5, 0.5 end
function Region:SetTextColor(r, g, b) self.color = { r, g, b } end
function Region:SetText(text) self.label = text end
function Region:GetText() return self.label end
function Region:GetTextWidth() return #(self.label or "") * 6 end
function Region:GetStringWidth() return #(self.label or "") * 6 end

-- Each line of a font string is 12 px tall; rows hold at most two.
function Region:GetStringHeight()
    if not self.label or self.label == "" then return 0 end
    local _, breaks = self.label:gsub("\n", "")
    return (breaks + 1) * 12
end
function Region:SetTexture(texture) self.texture = texture end
function Region:SetAtlas(atlas) self.atlas = atlas end
function Region:SetBlendMode() end
function Region:CreateFontString() return newRegion("FontString", nil, self) end
function Region:CreateTexture() return newRegion("Texture", nil, self) end

-- Blizzard template setup, reduced to the keys and calls the library and the addon use.
local templates = {}
templates.ButtonFrameTemplate = function(f)
    f.Inset = newRegion("Frame", nil, f)
    f.SetTitle = function(self, title) self.title = title end
    f.SetPortraitToAsset = function(self, icon) self.portrait = icon end
end
templates.UIPanelButtonTemplate = function(f) f:SetSize(40, 22) end
templates.MagicButtonTemplate = function(f) f:SetSize(80, 22) end
templates.ScrollFrameTemplate = function(f)
    f.ScrollBar = newRegion("EventFrame", nil, f)
    f.ScrollBar.SetHideIfUnscrollable = function() end
    f.UpdateScrollChildRect = function() end
    f.GetVerticalScrollRange = function(self) return math.max(0, self.scrollChild.height - self.height) end
    f.SetVerticalScroll = function(self, offset) self.scrollOffset = offset end
end

-- SearchBoxTemplate fires OnTextChanged on every SetText, as the client does.
templates.SearchBoxTemplate = function(f)
    f.Instructions = f:CreateFontString()
    f.SetText = function(self, text)
        self.label = text
        runScript(self, "OnTextChanged", false)
    end
end

-- WowStyle1FilterDropdownTemplate: text FILTER, resizeToText, and WowDropdownFilterBehaviorMixin's reset.
templates.WowStyle1FilterDropdownTemplate = function(f)
    f:SetSize(135, 18)
    f.ResetButton = newRegion("Button", nil, f)
    f.ResetButton.shown = false
    f.SetDefaultCallback = function(self, fn) self.defaultCallback = fn end
    f.SetIsDefaultCallback = function(self, fn) self.isDefaultCallback = fn end
    f.ValidateResetState = function(self) self.ResetButton.shown = not self.isDefaultCallback() end
    f.SetupMenu = function(self, generator)
        self.generator = generator
        self:ValidateResetState()
    end
end

function CreateFrame(kind, name, parent, template)
    local f = newRegion(kind, name, parent)
    if template then
        local setup = templates[template]
        if not setup then error("no stub for template " .. template) end
        setup(f)
    end
    if name then _G[name] = f end
    return f
end

UIParent = CreateFrame("Frame", "UIParent")

-- Tooltips collect their lines.
local function newTooltip(name)
    local tooltip = CreateFrame("GameTooltip", name, UIParent)
    tooltip.lines = {}
    tooltip.SetOwner = function(self) self.lines = {} end
    tooltip.AddLine = function(self, text) table.insert(self.lines, text) end
    tooltip.NumLines = function(self) return #self.lines end
    tooltip.IsForbidden = function() return false end
    return tooltip
end
GameTooltip = newTooltip("GameTooltip")
ItemRefTooltip = newTooltip("ItemRefTooltip")
function GameTooltip_Hide() GameTooltip:Hide() end
function GameTooltip_SetTitle(tooltip, text) tooltip:AddLine(text) end
function GameTooltip_AddBlankLineToTooltip(tooltip) tooltip:AddLine("") end
function GameTooltip_AddHighlightLine(tooltip, text) tooltip:AddLine(text) end
function GameTooltip_AddNormalLine(tooltip, text) tooltip:AddLine(text) end
function GameTooltip_AddDisabledLine(tooltip, text) tooltip:AddLine(text) end
function GameTooltip_AddInstructionLine(tooltip, text) tooltip:AddLine(text) end
function GameTooltip_AddColoredLine(tooltip, text) tooltip:AddLine(text) end
function GameTooltip_AddColoredDoubleLine(tooltip, left, right) tooltip:AddLine(left .. ": " .. right) end
function MagicButton_OnLoad() end
TooltipDataProcessor = { AddTooltipPostCall = function() end }

-- Client API with one Alliance character at level 10, standing in Elwynn Forest.
local player = { level = 10, inCombat = false, instanceType = "none" }
function UnitLevel() return player.level end
function UnitXPMax() return 1000 end
function UnitFactionGroup() return "Alliance" end
function GetMaxPlayerLevel() return 60 end
function InCombatLockdown() return player.inCombat end
function IsModifiedClick() return false end
function IsModifierKeyDown() return false end
function IsInInstance() return player.instanceType ~= "none", player.instanceType end
function BreakUpLargeNumbers(n) return tostring(n) end
function hooksecurefunc(owner, name, hook)
    if type(owner) == "string" then owner, name, hook = _G, owner, name end
    local original = owner[name] or function() end
    owner[name] = function(...)
        local results = { original(...) }
        hook(...)
        return unpack(results)
    end
end
unpack = unpack or table.unpack
issecretvalue = function() return false end
issecrettable = function() return false end

local AREAS = { [12] = "Elwynn Forest", [40] = "Westfall" }
local mapCalls = {}
C_Map = {
    GetAreaInfo = function(areaId) return AREAS[areaId] end,
    GetMapArtLayers = function() return { {} } end,
    GetMapInfo = function() return nil end,
    CanSetUserWaypointOnMap = function() return true end,
    SetUserWaypoint = function(point) mapCalls.waypoint = point end,
}
UiMapPoint = { CreateFromCoordinates = function(mapId, x, y) return { mapId = mapId, x = x, y = y } end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
C_QuestLog = { IsEliteQuest = function(questId) return questId == 103 end }
function OpenWorldMap(mapId) mapCalls.opened = mapId end
function SetItemRef() end
ChatFrameUtil = { GetActiveWindow = function() return nil end }

-- Questie with a small world: quests, givers and the player's log and completed set.
local QUESTS = {
    [101] = { name = "Wolves Across the Border", level = 10, requiredLevel = 8, zoneOrSort = 12, startedBy = { { 1001 } }, xp = 450 },
    [102] = { name = "Kobold Candles", level = 11, requiredLevel = 9, zoneOrSort = 12, startedBy = { { 1002 } }, xp = 600 },
    [103] = { name = "Princess Must Die", level = 12, requiredLevel = 10, zoneOrSort = 12, startedBy = { { 1001 } }, xp = 900, tag = 1 },
    [104] = { name = "The Defias Brotherhood", level = 14, requiredLevel = 11, zoneOrSort = 40, startedBy = { { 1003 } }, xp = 1400 },
    [105] = { name = "Red Linen Goods", level = 9, requiredLevel = 6, zoneOrSort = 12, startedBy = { { 1002 } }, xp = 300, preQuestSingle = { 101 } },
    [106] = { name = "Westfall Stew", level = 10, requiredLevel = 8, zoneOrSort = 40, startedBy = { { 1003 } }, xp = 500 },
    [107] = { name = "A Fishy Peril", level = 9, requiredLevel = 7, zoneOrSort = 12, startedBy = { { 1001 } }, finishedBy = { { 1001 } }, xp = 350 },
    [108] = { name = "Red Silk Bandanas", level = 12, requiredLevel = 10, zoneOrSort = 40, startedBy = { { 1003 } }, xp = 800, tag = 81 },
}
local NPCS = {
    [1001] = { name = "Marshal Dughan", friendlyToFaction = "A", spawns = { [12] = { { 42.1, 65.9 } } } },
    [1002] = { name = "William Pestle", friendlyToFaction = "A", spawns = { [12] = { { 43.3, 65.7 } } } },
    [1003] = { name = "Gryan Stoutmantle", friendlyToFaction = "A", spawns = { [40] = { { 56.3, 47.5 } } } },
}
local questLog = { [106] = true, [107] = true }
local completed = {}

local modules = {}
local function module(name)
    modules[name] = modules[name] or {}
    return modules[name]
end
QuestieLoader = { ImportModule = function(_, name) return module(name) end }

local QuestieDB = module("QuestieDB")
QuestieDB.QuestPointers = {}
for questId in pairs(QUESTS) do QuestieDB.QuestPointers[questId] = true end
QuestieDB.questKeys = { parentQuest = 25, availableUntilCompleted = 30 }
QuestieDB.autoBlacklist = {}
function QuestieDB.QueryQuestSingle(questId, key) return QUESTS[questId] and QUESTS[questId][key] end
function QuestieDB.QueryQuest() return nil end
function QuestieDB.QueryNPCSingle(npcId, key) return NPCS[npcId] and NPCS[npcId][key] end
function QuestieDB.QueryObjectSingle() return nil end
function QuestieDB.QueryItemSingle() return nil end
function QuestieDB:GetNPC(npcId) return NPCS[npcId] end
function QuestieDB.GetQuest(questId)
    local quest = QUESTS[questId]
    return quest and { requiredLevel = quest.requiredLevel, objectivesText = { "Do the thing." } }
end
function QuestieDB:IsPreQuestSingleFulfilled(preIds)
    for _, preId in ipairs(preIds) do
        if completed[preId] then return true end
    end
    return false
end
function QuestieDB:IsPreQuestGroupFulfilled(preIds)
    for _, preId in ipairs(preIds) do
        if not completed[preId] then return false end
    end
    return true
end
function QuestieDB.IsDoable(questId)
    if questLog[questId] or completed[questId] then return false end
    local preIds = QUESTS[questId].preQuestSingle
    return not preIds or QuestieDB:IsPreQuestSingleFulfilled(preIds)
end
function QuestieDB.IsRepeatable() return false end
function QuestieDB.IsComplete(questId) return questId == 107 and 1 or 0 end
function QuestieDB.IsTrivial(level) return level < player.level - 5 end
function QuestieDB.GetQuestTagInfo(questId) return QUESTS[questId].tag end
function QuestieDB.RefreshAfterCorrectionApply() end

local QuestieLib = module("QuestieLib")
function QuestieLib.GetEffectiveQuestLevel(questId)
    local quest = QUESTS[questId]
    return quest.level, quest.requiredLevel, 0
end
function QuestieLib:GetColoredQuestName(questId) return QUESTS[questId].name end
function QuestieLib:GetDifficultyColorPercent() return 1, 1, 0 end

local QuestiePlayer = module("QuestiePlayer")
QuestiePlayer.currentQuestlog = questLog
function QuestiePlayer.HasRequiredRace() return true end
function QuestiePlayer.HasRequiredClass() return true end
function QuestiePlayer:GetCurrentZoneId() return 12 end

local ZoneDB = module("ZoneDB")
function ZoneDB:GetUiMapIdByAreaId(areaId) return areaId + 1400 end
function ZoneDB:GetLocalizedDungeonName() return nil end

module("QuestXP").GetQuestLogRewardXP = function(_, questId) return QUESTS[questId].xp end
module("QuestieMap").GetFramesForQuest = function() return {} end
module("QuestieCorrections").hiddenQuests = {}
module("QuestieTooltips").lookupByKey = {}
module("QuestieFrame").CreateIconFrame = function() end
module("QuestieCompat").GetQuestGreenRange = function() return 5 end
module("AvailableQuests").ResetLevelRequirementCache = function() end
module("QuestieEvent").activeQuests = {}

local readyCallbacks = {}
Questie = {
    LOWLEVEL_ALL = 1, LOWLEVEL_OFFSET = 2, LOWLEVEL_RANGE = 3,
    Colorize = function(_, text) return text end,
    db = {
        char = { complete = completed, hidden = {} },
        profile = { lowLevelStyle = 0, manualLevelOffset = 5, minLevelFilter = 1, maxLevelFilter = 60,
            enableTooltips = true, enableTooltipsQuestLevel = true, showQuestsInNpcTooltip = true },
    },
    API = {
        RegisterOnReady = function(fn) readyCallbacks[#readyCallbacks + 1] = fn end,
        RegisterForQuestUpdates = function() end,
        Enums = { QuestUpdateTriggerReason = { QUEST_UPDATED = 1 } },
    },
}

local function load(path, ...)
    local chunk, err = loadfile(ROOT .. path)
    if not chunk then error(err) end
    chunk(...)
end

-- The launcher's two libraries, reduced to the calls UI.CreateLauncher makes.
local function stubLauncherLibs()
    local LDB = LibStub:NewLibrary("LibDataBroker-1.1", 1)
    function LDB:NewDataObject(name, object) self[name] = object; return object end
    local LDBIcon = LibStub:NewLibrary("LibDBIcon-1.0", 1)
    LDBIcon.registered = {}
    function LDBIcon:IsRegistered(name) return self.registered[name] ~= nil end
    function LDBIcon:Register(name, object, db) self.registered[name] = { object = object, db = db } end
    function LDBIcon:AddButtonToCompartment() end
    function LDBIcon:Show() end
    function LDBIcon:Hide() end
end
local STUBBED = {
    ["Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua"] = true,
    ["Libs/LibDataBroker-1.1/LibDataBroker-1.1.lua"] = true,
    ["Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua"] = true,
}

-- Every toc file in order; the three launcher libraries are replaced by the stubs above.
local ns = {}
local loaded = 0
for line in io.lines(ROOT .. ADDON_NAME .. ".toc") do
    local path = line:match("^%s*([^#%s][^\r]*%.lua)%s*$")
    if path then
        path = path:gsub("\\", "/")
        if not STUBBED[path] then
            local ok, err = pcall(load, path, ADDON_NAME, ns)
            check("loads " .. path, ok, err)
            loaded = loaded + 1
        end
        if path == "Libs/LibStub/LibStub.lua" then
            stubLauncherLibs()
        end
    end
end
check("toc lists the addon files", loaded >= 3, loaded)


local function fireEvent(event, ...)
    for _, frame in ipairs(eventFrames) do
        if frame.events[event] and frame.scripts.OnEvent then
            frame.scripts.OnEvent(frame, event, ...)
        end
    end
end

local function plain(text)
    return (text:gsub("|cff", ""):gsub("|r", ""))
end

-- The list rows on screen, top to bottom, as plain text.
local function listRows()
    local rows = {}
    for _, region in ipairs(QuestieGuideFrame.scroll.content.children) do
        if region.shown and region.text and region.text.label then
            rows[#rows + 1] = region
        end
    end
    table.sort(rows, function(a, b) return a.points[1].y > b.points[1].y end)
    return rows
end

local function rowTexts()
    local texts = {}
    for i, row in ipairs(listRows()) do texts[i] = plain(row.text.label) end
    return texts
end

local function findRow(fragment)
    for _, row in ipairs(listRows()) do
        if row.text.label:find(fragment, 1, true) then return row end
    end
end

local function hasLine(lines, fragment)
    for _, line in ipairs(lines) do
        if plain(line):find(fragment, 1, true) then return true end
    end
    return false
end

-- Login: saved variables, Questie's ready callback, then PLAYER_LOGIN.
fireEvent("ADDON_LOADED", ADDON_NAME)
check("saved variables get their defaults", type(QuestieGuideDB) == "table" and QuestieGuideDB.sortMode == "xp"
    and QuestieGuideDB.filters.inLog == true and QuestieGuideDB.levelBelow == 5)
check("waits for Questie's ready callback", #readyCallbacks == 1, #readyCallbacks)
for _, ready in ipairs(readyCallbacks) do ready() end
fireEvent("PLAYER_LOGIN")
check("launcher registers with LibDBIcon", LibStub("LibDBIcon-1.0"):IsRegistered("Questie Guide"))
check("no chat at login", #chat == 0, chat[1])
check("slash command registers", SLASH_QUESTIEGUIDE1 == "/questieguide" and SLASH_QUESTIEGUIDE2 == "/qg")
flushTimers()

-- Open: the loading line first, then the list on the next tick.
SlashCmdList.QUESTIEGUIDE("")
check("window opens", QuestieGuideFrame and QuestieGuideFrame:IsShown())
check("window is the fixed 680 x 624", QuestieGuideFrame.width == 680 and QuestieGuideFrame.height == 624)
check("loading line paints first", rowTexts()[1] == "Scanning quest database\226\128\166", rowTexts()[1])
flushTimers()
local opened = rowTexts()
check("banner names the best zone", opened[1] == "Next: Elwynn Forest  2600 XP in one trip, covers 260% of level 10", opened[1])
check("completed section lists the turn-in", findRow("Completed Quests (1)") ~= nil and findRow("A Fishy Peril") ~= nil)
check("current zone header carries XP and the marker", findRow("Elwynn Forest (5) ") ~= nil
    and findRow("Elwynn Forest (5) "):GetHeight() == 16)
check("elite quest reads like the quest log", findRow("[12+] Princess Must Die") ~= nil
    and plain(findRow("Princess Must Die").text.label):find("(Elite)", 1, true) ~= nil)
check("blocked quest shows its badge", findRow("[Missing Pre-Quest]") ~= nil
    and findRow("Red Linen Goods").alpha == 0.5)

-- Under the stub's 12 px lines a two-line row is 24 + 8 padding; in game it snaps to 36 (UNVERIFIED).
check("a two-line quest row snaps to the grid", findRow("Wolves Across the Border"):GetHeight() == 32,
    findRow("Wolves Across the Border"):GetHeight())
check("Westfall starts collapsed", findRow("Westfall (2)") ~= nil and findRow("Red Silk Bandanas") == nil)
check("Collapse All reads the expanded state", QuestieGuideFrame.toggleAllButton.label == "Collapse All")

-- Tooltips: a quest row, the chain on a blocked row and the launcher.
local wolves = findRow("Wolves Across the Border")
wolves.scripts.OnEnter(wolves)
check("quest tooltip names the giver", hasLine(GameTooltip.lines, "NPC: Marshal Dughan"))
local linen = findRow("Red Linen Goods")
linen.scripts.OnEnter(linen)
check("chain tooltip lists the first step", hasLine(GameTooltip.lines, "1. [10] Wolves Across the Border"))
LibStub("LibDataBroker-1.1")["Questie Guide"].OnTooltipShow(GameTooltip)
check("launcher tooltip names the Next zone", hasLine(GameTooltip.lines, "Next: Elwynn Forest, 2600 XP."))
check("launcher counts only quests to pick up", hasLine(GameTooltip.lines, "3 quests to pick up in Elwynn Forest."))

-- A stale scan still feeds the launcher, minus quests accepted since.
questLog[102] = true
ns.invalidateScan()
LibStub("LibDataBroker-1.1")["Questie Guide"].OnTooltipShow(GameTooltip)
check("stale scan skips a quest accepted since", hasLine(GameTooltip.lines, "2 quests to pick up in Elwynn Forest."))
questLog[102] = nil

-- Entering an instance: one line per visit, counting neither the blocked nor the in-log row.
chat = {}
player.instanceType = "party"
fireEvent("ZONE_CHANGED_NEW_AREA")
fireEvent("ZONE_CHANGED_NEW_AREA")
check("dungeon line counts pickable quests once", #chat == 1
    and plain(chat[1]):find("[Elwynn Forest]|h: 3 quests you could still pick up.", 1, true) ~= nil, chat[1])
player.instanceType = "none"
fireEvent("ZONE_CHANGED_NEW_AREA")
flushTimers()

-- In combat a row click lands the waypoint, keeps the map closed and says why.
chat, mapCalls.opened, mapCalls.waypoint = {}, nil, nil
player.inCombat = true
wolves.scripts.OnClick(wolves, "LeftButton")
flushTimers()
check("combat click sets only the waypoint", mapCalls.waypoint ~= nil and mapCalls.opened == nil
    and #chat == 1 and hasLine(chat, "after combat."), chat[1])
player.inCombat = false

-- A row click sets the waypoint and opens the map at the giver.
wolves.scripts.OnClick(wolves, "LeftButton")
flushTimers()
check("row click opens the giver's map", mapCalls.opened == 1412 and mapCalls.waypoint and mapCalls.waypoint.mapId == 1412)
check("clicked row is selected", findRow("Wolves Across the Border").selection.shown)

-- Filter menu: the template's reset button follows the filters.
local filter = QuestieGuideFrame.filterDropdown
local entries = {}
local function newDescription()
    local description = {}
    function description:CreateTitle(text) entries[#entries + 1] = text end
    function description:CreateDivider() end
    function description:CreateCheckbox(text, _, toggle) entries[#entries + 1] = text; entries[text] = toggle end
    function description:CreateRadio(text, _, select) entries[#entries + 1] = text; entries["radio:" .. text] = select end
    function description:CreateButton(text) entries[#entries + 1] = text; return newDescription() end
    return description
end
filter.generator(filter, newDescription())
check("filter menu holds every family", entries[1] == "Availability" and entries["Show Completed"] ~= nil
    and hasLine(entries, "Level Range") and hasLine(entries, "Sort By"))
check("reset hidden at defaults", filter.ResetButton.shown == false)
entries["Show Completed"]()
filter:ValidateResetState()
check("a changed filter shows reset and re-renders", filter.ResetButton.shown and findRow("Completed Quests") == nil)
filter.defaultCallback()
filter:ValidateResetState()
check("reset restores the defaults", QuestieGuideDB.showCompleted and not filter.ResetButton.shown
    and findRow("Completed Quests") ~= nil)
check("range radios keep the menu open, sort radios close it",
    entries["radio:Questie Level Ranges"]() == MenuResponse.Refresh and entries["radio:Total XP"]() == nil)
filter.defaultCallback()

-- Level change: a rescan, a new Next zone and one chat line with the zone link.
chat = {}
player.level = 11
fireEvent("PLAYER_LEVEL_CHANGED", 10, 11)
flushTimers()
check("level up rescans into the new Next zone", rowTexts()[1]:find("Next: Westfall  2700 XP", 1, true) ~= nil, rowTexts()[1])
check("newly unlocked quest lists", findRow("The Defias Brotherhood") ~= nil)
check("in-log quest shows its status", findRow("Westfall Stew") ~= nil
    and findRow("Westfall Stew").text.label:find("[In Questlog]", 1, true) ~= nil)
check("one chat line names the new quests", #chat == 1
    and plain(chat[1]):find("New quests at level 11: 1 in |Haddon:questieguide:zone:40|h[Westfall]|h.", 1, true) ~= nil, chat[1])

-- Search: matching rows expand, the banner hides, and clearing restores the list.
QuestieGuideFrame.searchBox:SetText("kobold")
local searched = rowTexts()
check("search keeps only matches", findRow("Kobold Candles") ~= nil and findRow("Wolves Across the Border") == nil
    and findRow("Next:") == nil, table.concat(searched, " / "))
QuestieGuideFrame.searchBox:SetText("zzz")
check("an empty search explains itself", findRow("No quests match") ~= nil)
QuestieGuideFrame.searchBox:SetText("")
check("clearing the search restores the banner", rowTexts()[1]:find("Next: Westfall", 1, true) ~= nil)

-- Close and reopen through the binding.
QuestieGuide_Toggle()
check("binding closes the window", not QuestieGuideFrame:IsShown())

-- Questie map pins: only an available "!" opens the guide.
QuestieFrame1 = CreateFrame("Button", "QuestieFrame1")
QuestieFrame1.miniMapIcon = true
modules.QuestieFrame.CreateIconFrame(1)
QuestieFrame1.data = { Id = 102, Type = "monster" }
runScript(QuestieFrame1, "OnClick", "LeftButton")
check("objective pin leaves the guide closed", not QuestieGuideFrame:IsShown())
QuestieFrame1.data = { Id = 102, Type = "available" }
runScript(QuestieFrame1, "OnClick", "LeftButton")
flushTimers()
check("available pin opens the guide at the quest", QuestieGuideFrame:IsShown() and findRow("Kobold Candles") ~= nil
    and findRow("Kobold Candles").selection.shown)

print = realPrint
print(string.format("QuestieGuide smoke test: %d passed, %d failed", passes, failures))
if failures > 0 then os.exit(1) end
