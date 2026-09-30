# QuestieGuide — Memory

Updated 2026-09-30 after the Forever-only rework (2.0.0). The owner's decision: WoW Forever 1.60.x only. `main` holds only the Forever version; `1.15.x-backup` keeps the Classic version. Quest data comes only from Questie.

Verified against:

- Gethe `forever` @ `966519cf` (1.60.1.70124), only files the Forever client loads
- Ketho `forever` @ `4149af64` (1.60.1.70009)
- the installed Questie 12.0.3 (`Questie_Camelot.toc`) with QuestieDB 1.0.4 (Forever flavor, baked)
- the installed client 1.60.1.70009

Nothing has run in a client.

## Current state

Lists every quest you can pick up now, grouped by zone, from Questie's database. On top of that list it adds:

- Trip XP including follow-ups, and a "Next:" banner.
- Status labels and a chain tooltip that jumps to the step you can do.
- A map jump to the quest giver: through TomTom when it's installed, otherwise the native user waypoint and beacon.
- Filters, sorting, a completed-quests section, item-tooltip lines and a level-up toast.
- A minimap button, the Addon Compartment, `/qg`, a key binding, and click-through from Questie's map icons.

| Item | State |
|---|---|
| Version | 2.0.0: `## Interface: 16001`, `## Category: Quests`, `## RequiredDeps: Questie`, `## IconTexture: Interface\Icons\INV_Misc_Map02`, Addon Compartment fields |
| Files | One Lua file (`QuestieGuide.lua`, 3,219 lines, was 3,557), `Bindings.xml`, the toc, and the four tracked libs in `Libs/` (LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0) |
| Git | `1.15.x-backup` = `origin/1.15.x-backup` = `c50c068` (the dual-client 1.1.0, created by the lead). `main` carries the 2.0.0 commits, not pushed |
| Offline checks | `luac -p` passes (5.5). Lua 5.1 limits estimated from the luac 5.5 listing: main chunk at most 130 active locals (was 182, limit 200), `renderList` 47 upvalues (was 51, limit 60) |

## How it talks to Questie

Readiness and refresh use Questie's public API (`Questie/Public/`), which Questie calls stable:

- `Questie.API.RegisterOnReady(fn)` is registered at our `ADDON_LOADED`. Questie calls it at the end of Stage 3 (`QuestieInit.lua:342-343`), after its tooltip post-calls, quest log and completed set exist.
- The ready callback runs one fail-closed field check, then installs the item-tooltip post-call, the map-icon hooks, the correction hook and `Questie.API.RegisterForQuestUpdates`, and schedules the item index 5 s later.
- `RegisterForQuestUpdates(fn)` gets `(questId, objectiveIndex, triggerReason)`. `QUEST_UPDATED` only re-renders; accept, turn-in and abandon also invalidate the scan. All go through the 0.5 s debounce. On accept Questie calls back before `QuestLifecycle:AcceptQuest` adds the quest to `currentQuestlog` (`QuestEventHandler.lua:262` then `QuestLifecycle.lua:98`), so the debounce matters.
- Until ready, every launcher prints "Questie has not finished loading yet". If Questie's init aborts, ready never comes and the message stays; there is no polling.
- `Questie.API` itself is checked at `ADDON_LOADED` (`RegisterOnReady`, `RegisterForQuestUpdates`, `Enums.QuestUpdateTriggerReason`).

The fail-closed check (`QUESTIE_FIELDS`) covers every internal the code reads. One missing field prints its name and keeps the window closed for the session. It is per field because `QuestieLoader:ImportModule` returns an empty module, never nil. The fields and where they live in the installed Questie 12.0.3:

- `QuestieDB`: `QuestPointers` (bound at `QuestieDB.lua:467`), `QueryQuestSingle`/`QueryNPCSingle`/`QueryItemSingle`/`QueryObjectSingle`/`QueryQuest` (`:443-447`), `GetNPC` (`:2039`), `GetQuest` (`:1658`), `IsDoable` (`:873`), `IsPreQuestSingleFulfilled` (`:856`), `IsPreQuestGroupFulfilled` (`:821`), `IsRepeatable` (`:656`), `IsComplete` (`:1604`), `IsTrivial` (`:1627`), `GetQuestTagInfo` (`:769`), `autoBlacklist` (`:54`), `RefreshAfterCorrectionApply` (`:523`)
- `QuestieLib` (`Modules/Libs/QuestieLib.lua`): `GetDifficultyColorPercent` (`:71`), `GetColoredQuestName` (`:151`), `GetEffectiveQuestLevel` (`:224`)
- `QuestiePlayer` (`Modules/QuestiePlayer.lua`): `currentQuestlog` (`:15`), `HasRequiredRace` (`:93`), `HasRequiredClass` (`:110`), `GetCurrentZoneId` (`:116`)
- `ZoneDB` (`Database/Zones/zoneDB.lua`): `GetUiMapIdByAreaId` (`:141`), `GetLocalizedDungeonName` (`:209`)
- `QuestXP.GetQuestLogRewardXP` (`QuestieXP.lua:93`), `QuestieMap.GetFramesForQuest` (`QuestieMap.lua:81`), `QuestieCorrections.hiddenQuests` (`QuestieCorrections.lua:28`), `QuestieTooltips.lookupByKey` (`Tooltip.lua:28`), `QuestieFrame.CreateIconFrame` (`QuestieFrame.lua:47`)
- `Questie.Colorize` (`Questie.lua:127`), `Questie.db`, and `Questie.db.char.complete` / `.hidden`

Module tables are imported at file load (`## RequiredDeps: Questie` loads Questie first); their data is only read after ready. Fields Questie reassigns (`QuestPointers`, `currentQuestlog`, `autoBlacklist`, `hiddenQuests`, `Questie.db.char.complete`) are always read through their owner, never cached.

Integration facts, still valid:

- Load order is QuestieDB → Questie → QuestieGuide. `Questie_Camelot.toc` has `## RequiredDeps: QuestieDB`. The addon never touches LibQuestieDB, so it needs no QuestieDB dependency of its own.
- Contract 2 on both sides is enforced by Questie itself (`VersionCheckDB.lua:21`).
- Insecure tooltip post-calls run in registration order (`TooltipDataHandler.lua:61-68`), so ours, registered at ready, land under Questie's Stage 3 lines. That fixes the double "(Available)" on the first hover of a quest-start item (QG-05).
- `QuestPointers` is an `{id=true}` hashmap, and every table-valued read returns a fresh copy (`shared.lua:365-372`). QuestieDB Forever has about 4,257 quests.
- Questie map pins are `QuestieFrameN`, created through `QuestieFrame.CreateIconFrame`, so the `hooksecurefunc` catches every new pin; a sweep at ready covers pins drawn before it.
- The waypoint uses the same area-to-map table and spawn data as Questie's own pins.
- The bundled LibDBIcon (minor 56) overrides Questie's 55.
- Questie writes Policy Corrections after login too: the Darkmoon Faire NPC slot waits for `CALENDAR_UPDATE_EVENT_LIST` (`QuestieEvent.lua:136-147`), and item-name repairs run on quest accept (`QuestieLib.lua:470-485`). All go through `QuestieDB.RefreshAfterCorrectionApply`, which the guide post-hooks (QG-21).

## Quest data: Questie vs native

Switched from native to Questie in 2.0.0:

| Data | Was | Now |
|---|---|---|
| Completion flag | `C_QuestLog.IsQuestFlaggedCompleted` | `Questie.db.char.complete`, the set Questie's `IsDoable` and prerequisite checks read. Repeatables are not marked there unless daily/weekly/monthly (`QuestLifecycle.lua:142`) |
| Grey / green range | `UnitQuestTrivialLevelRange("player")` | `QuestieDB.IsTrivial` for grey, QuestieLib's tiers for orange (+3) and red (+5) |
| "Is in the quest log" before opening the log | `C_QuestLog.GetLogIndexForQuestID` | `QuestiePlayer.currentQuestlog` |
| Quest change events | `QUEST_ACCEPTED`, `QUEST_REMOVED`, `QUEST_TURNED_IN`, `UNIT_QUEST_LOG_CHANGED` | `Questie.API.RegisterForQuestUpdates` |

Already from Questie and unchanged: quest log contents, names, levels (`GetEffectiveQuestLevel`), difficulty colours, objectives, XP, tags, givers and turn-ins, zones, prerequisites, race/class gates, hidden and blacklisted quests, completeness of log quests.

Native calls that stay, and why:

- `C_Map.GetAreaInfo(areaId)`: the zone name for a Questie area id. Questie resolves names the same way (`TrackerUtils:GetZoneNameByID` and `ZoneDB:GetLocalizedDungeonName` both call it first); `ZoneDB:GetLocalizedDungeonName` is the fallback here too.
- `UnitLevel`, `UnitXPMax`, `GetMaxPlayerLevel`, `UnitFactionGroup` ("player"): the player's own level, XP, level cap and faction, not quest data. Questie's own `_AddStarter` and `QuestXP` read the same calls.
- `QuestMapFrame_OpenToQuestDetails`: opens Blizzard's quest log.
- `OpenWorldMap`, `C_Map.GetMapArtLayers`, `C_Map.GetMapInfo`, `WorldMapFrame:GetMapID`: the map jump.
- `C_Map.CanSetUserWaypointOnMap`, `C_Map.SetUserWaypoint`, `UiMapPoint.CreateFromCoordinates`, `C_SuperTrack.SetSuperTrackedUserWaypoint`: the waypoint.
- `TooltipDataProcessor.AddTooltipPostCall` with `data.id`: which item a tooltip shows.
- `ChatFrameUtil.GetActiveWindow` / `InsertLink` / `OpenChat`: chat links.
- Events `PLAYER_LEVEL_UP` (payload level) and `ZONE_CHANGED_NEW_AREA`: the player's level and location.

Questie calls that wrap natives: `QuestieDB.GetQuestTagInfo` (C_QuestLog.GetQuestTagInfo plus Questie's tag corrections and cache), `QuestieDB.IsComplete` (Questie's quest log cache), `QuestieDB.IsTrivial` (UnitQuestTrivialLevelRange via QuestieCompat), `QuestiePlayer:GetCurrentZoneId` (C_Map.GetBestMapForUnit plus ZoneDB).

## Native UI

- The window is `ButtonFrameTemplate` (`QuestieGuideFrame`), strata HIGH, toplevel, clamped, movable, portrait from the toc icon, title "Questie Guide", Escape via `UISpecialFrames`, built lazily. One toggle (`toggleIfReady`) serves `/qg`, the key binding, the minimap button and the compartment.
- Layout follows ChannelFrame: settings column in an `InsetFrameTemplate`, the list in the template's `.Inset`, both placed with `PANEL_INSET_*`. The search box (`SearchBoxTemplate`) sits in the attic like AddonList's.
- The list uses `ScrollFrameTemplate` (MinimalScrollBar); the gutter comes from the real bar width plus `SCROLL_FRAME_SCROLL_BAR_OFFSET_LEFT`, and `SCROLL_FRAME_SCROLL_BAR_OFFSET_TOP` (2) keeps the bar inside the inset.
- Bottom bar: two `MagicButtonTemplate` buttons (Collapse All, Current Zone) chained from BOTTOMLEFT with zero offsets, then `MagicButton_OnLoad`. They sit bottom-left because `PanelResizeButtonTemplate` (EventTrace's grip) owns the bottom-right corner; it always sizes from BOTTOMRIGHT (`SharedUIPanelTemplates.lua:1695`).
- Controls: `WowStyle1DropdownTemplate`, `MinimalSliderWithSteppersTemplate`, `UICheckButtonTemplate` (`.Text`), `UIPanelButtonTemplate` for the empty-state action, `MenuUtil.CreateContextMenu`.
- Row art from Forever's quest UI: hover `Interface\QuestFrame\UI-QuestTitleHighlight` (Forever's GossipFrame and quest greeting rows), selection atlas `questlog-quest-glow-yellow` (the called-out quest in Forever's quest log, `QuestMapFrame.xml:227`, `QuestMapFrame.lua:1956`), header toggles `UI-PlusButton-Up` / `UI-MinusButton-Up` / `UI-PlusButton-Hilight` (Forever's Group Finder listing, `Blizzard_LFGVanilla_Listing.lua:956-958`).
- Colours are Blizzard colour objects (`GRAY`, `NORMAL`, `YELLOW`, `LIGHTBLUE`, `GREEN`, `ORANGE`, `LINK`, `RED`, `HIGHLIGHT` `_FONT_COLOR`, `EPIC_PURPLE_COLOR`) and `QuestDifficultyColors.header` for header grey. Exceptions: level and name colours are Questie's difficulty colour (`CreateColor` of `GetDifficultyColorPercent`), and item-tooltip status suffixes use `Questie:Colorize` so they match Questie's own lines above them.
- Fonts: Blizzard font objects only. Tooltips: the `GameTooltip_*` helpers.
- Minimap button: LibDBIcon with an LDB launcher "Questie Guide", icon = toc icon, db at `QuestieGuideDB.minimap`.

Forever facts:

- `OpenWorldMap(mapID)` exists and honours the WorldMapDisabled game rule (`Blizzard_WorldMap.lua:1408-1414`).
- `Enum.QuestTag` 1 is Group (`LuaEnum.lua:6714`, group icon at `Blizzard_FrameXMLBase/Constants.lua:527`). Camelot marks elites with `C_QuestLog.IsEliteQuest` (`Camelot/QuestMapFrameOverrides.lua:15-21`), which Questie doesn't expose.
- Forever's yellow difficulty band is -4..+2 (`Mainline/DifficultyUtil.lua:36-47`); the guide uses Questie's tiers (yellow -2..+2), which only differ in colour, not in what counts as grey or orange.
- `BreakUpLargeNumbers(number)` is a C API on Forever (`LocalizationDocumentation.lua:42`).

Fixed in the port and still valid:

- `{-1,-1}` dungeon spawns no longer show coordinates or set a waypoint.
- A zone is no longer paired with another zone's spawn.

## Audit 2026-09-30 → 2.0.0

| ID | Finding | Done in 2.0.0 |
|---|---|---|
| QG-01 | No backup branch | Done by the lead: `1.15.x-backup` at `c50c068` (1.1.0), local and on GitHub |
| QG-02 | Dual interface line | `## Interface: 16001` |
| QG-03 | `Client` compat table, Era quest log | Deleted; Forever calls inlined (waypoint, chat, quest log, item tooltip) |
| QG-04 | `OnTooltipSetItem` preferred | Only `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, …)` with `data.id` |
| QG-05 | Item post-call registered before Questie's | Installed from `RegisterOnReady` |
| QG-06 | `Questie.started` plus a 5 s retry loop | `Questie.API.RegisterOnReady`; no polling left |
| QG-07 | Rescans raced Questie's own handler | `Questie.API.RegisterForQuestUpdates` with the debounce; native quest events dropped |
| QG-08 | Questie-11-vs-12 compat layer | One fail-closed field check; 25 optional toggles, raw-field fallbacks and guards removed |
| QG-09 | Hard-coded 60 | `GetMaxPlayerLevel()`; `passesClassicCaps` is now `passesLevelCap` |
| QG-10 | Full-database walk on open and level-up | Open: needs in-game timing |
| QG-11 | Pre-1.0 SavedVariables migrations | Deleted; one `applyDefaults` fills and type-checks every key |
| QG-12 | TomTom branch | Blocked, unchanged |
| QG-13 | Animation probes | Direct `SetScaleFrom/To` and `SetFromAlpha/ToAlpha`; one pulse helper |
| QG-14 | `ShowUIPanel(WorldMapFrame)` plus guards | `OpenWorldMap(renderMapId)` |
| QG-15 | Redundant guards, `formatNumber`, defaults twice | Guards removed, `BreakUpLargeNumbers`, defaults only in `DEFAULTS` |
| QG-16 | Tag 1 labelled Elite | Relabelled Group (settled by the Forever source); elite detection stays open, see questions |
| QG-17 | Era and both-client comments | Rewritten |
| QG-18 | Era README | Forever only |
| QG-19 | toc metadata | `## Category: Quests`, `## RequiredDeps: Questie`, one icon path, 2.0.0 |
| QG-20 | Near Lua 5.1 limits | Main chunk 130 active locals (single-use helpers in `do` blocks), `renderList` 47 upvalues. Estimated from luac 5.5; no 5.1 compiler here |
| QG-21 | Caches survive a correction | Post-hook on `QuestieDB.RefreshAfterCorrectionApply`: NPC, object and quest writes clear the giver, turn-in and reachability caches and rescan; quest writes also drop the follower index and rebuild the item index; item-name repairs are ignored |
| QG-22 | `wtqPulse` / `_wtqCount` on Questie's frames | `qgPulse` / `qgLoops` |

## Open items

Owner questions:

1. TomTom (QG-12): keep or drop the optional TomTom waypoint. Keep means no change; drop removes one branch in `openMapForQuest` and the README line.
2. Elite quests (QG-16): Forever marks elites only through `C_QuestLog.IsEliteQuest`, which Questie doesn't expose. Today the Elite (Group) filter covers Questie's Group and Raid tags, and no row says Elite. Yes: add that one native call, an `[Elite]` tag and filter membership (about 10 lines). No: rename the filter to "Group" or leave it.
3. "Use Questie Level Ranges": it applies Questie's yellow/green difficulty tiers, not the level range the player set in Questie's own options (`lowLevelStyle`, `minLevelFilter`, `maxLevelFilter`, `manualLevelOffset`). Keep: no change. Follow Questie's settings: replace the tier check with Questie's option logic (about 15 lines, four more profile fields in the check).
4. Resize grip vs button bar: the spec puts the primary MagicButton bottom-right, but the grip lives there. Keep resizing: buttons stay bottom-left (current). Drop resizing: buttons move bottom-right, the grip, `frameSize` and part of `/qg reset` go.

Robustness notes (not changed):

- QG-23: `QuestiePlayer:GetCurrentZoneId()` can raise an error through `ZoneDB:GetAreaIdByUiMapId` when a map has no area id (`zoneDB.lua:152-174`). `renderList` calls it every render, so an unmapped map would break the list. Questie itself calls it unguarded (for example `QuestiePlayer:GetCurrentContinentId`). A `pcall` in `getCurrentZoneName` would contain it.
- The dungeon-map art walk (`resolveRenderableMapId`) came from Era, where art-less maps crashed the map canvas. Unverified on Forever; kept as a harmless guard.

Unverified:

- Whether toc icon file ID `237381` (1.1.0) was `INV_Misc_Map02`. The toc now uses the path the portrait and minimap button already used, so the AddOn list icon changes if it wasn't.
- The `questlog-quest-glow-yellow` atlas and the plus/minus textures at our row sizes (stretched with `SetAllPoints`, toggles forced to 16x16).
- Whether opening the modern world map and quest log from addon code taints `WorldMapFrame` in combat.
- Whether the waypoint sits on the NPC. Setting it replaces the player's own waypoint.
- Whether the SavedVariables loss on a cold start, reported for an older beta, still happens on 70009.
- The layout at 640x480.

## Forever test checklist

Run `/console scriptErrors 1` first.

- [ ] `/reload`: no errors and no "Questie has no …" line. `/qg` before Questie is ready says it's still loading; after it opens.
- [ ] The window: portrait, strata over other panels, settings column left, list right, search top right, Collapse All and Current Zone bottom-left, grip bottom-right. It resizes down to 640x480, and size and position survive `/reload`. Escape closes it.
- [ ] The dropdowns, sliders and "Use Questie Level Ranges" work. Search filters the list and the clear button resets it.
- [ ] Clicking an Available quest opens the map at the giver, with the Questie pin pulsing. Clicking a Missing Pre-Quest row jumps to the prerequisite. The selected row shows the quest-log glow.
- [ ] Right-click → "Link in chat" inserts the link. A Questie map-icon click opens the guide, except while a chat box is open.
- [ ] Quest items in bags show their status line once, under Questie's lines. The first hover of a quest-start item doesn't show "(Available)" twice (QG-05).
- [ ] The compartment lists Questie Guide; the minimap button tooltip shows the zone count after the first scan.
- [ ] Without TomTom, an Available quest sets the native pin and beacon. `/dump C_Map.HasUserWaypoint(), C_SuperTrack.IsSuperTrackingUserWaypoint()` prints `true true`, and the pin sits on the NPC.
- [ ] An In Questlog row opens the quest map log on that quest.
- [ ] Accept a quest with the guide open: within a second the row flips to [In Questlog] (QG-07). Turn one in and abandon one: the list updates. Complete an objective: the Completed section updates.
- [ ] Time the first open and a level-up rescan (QG-10).
- [ ] `/dump GetMaxPlayerLevel(), UnitQuestTrivialLevelRange("player")` (QG-09), and check a known elite quest: `/dump C_QuestLog.GetQuestTagInfo(id), C_QuestLog.IsEliteQuest(id)` (question 2).
- [ ] Open the guide in combat and click a row: no "action blocked".
- [ ] Fully quit and restart: filters and position survive.
- [ ] Open the guide in every Forever-only zone and instance you reach: no error from `GetCurrentZoneId` (QG-23).
