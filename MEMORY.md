# QuestieGuide — Memory

Updated 2026-09-30 after the Forever-only rework (2.0.0) and the owner's round-2 decisions (TomTom, elite quests, Questie level ranges, fixed window size, colours), all still inside 2.0.0, which has not shipped. The owner's decision: WoW Forever 1.60.x only. `main` holds only the Forever version; `1.15.x-backup` keeps the Classic version. Quest data comes only from Questie.

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
- A map jump to the quest giver with the native user waypoint and beacon.
- Quest type tags (Elite (Group), Group, Dungeon, Raid, PvP), filters, sorting, a completed-quests section, item-tooltip lines and a level-up toast.
- A minimap button, the Addon Compartment, `/qg`, a key binding, and click-through from Questie's map icons.

| Item | State |
|---|---|
| Version | 2.0.0: `## Interface: 16001`, `## Category: Quests`, `## RequiredDeps: Questie`, `## IconTexture: Interface\Icons\INV_Misc_Map02`, Addon Compartment fields |
| Files | One Lua file (`QuestieGuide.lua`, 3,231 lines; 3,219 after the split, 3,557 before it), `Bindings.xml`, the toc, and the four tracked libs in `Libs/` (LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0) |
| Git | `1.15.x-backup` = `origin/1.15.x-backup` = `c50c068` (the dual-client 1.1.0, created by the lead). `main` carries the 2.0.0 commits, not pushed |
| Offline checks | `luac -p` passes (5.5). Lua 5.1 limits estimated from the luac 5.5 listing: main chunk at most 134 active locals (limit 200), `renderList` 48 upvalues (limit 60). The lead's throwaway smoke harness (mocked WoW API and fake Questie, kept in the session scratchpad, not in the repo) passes 53/53, including elite tagging, the Elite (Group) filter, all four Questie level styles, the bar anchors and the missing-profile-key path |

## How it talks to Questie

Readiness and refresh use Questie's public API (`Questie/Public/`), which Questie calls stable:

- `Questie.API.RegisterOnReady(fn)` is registered at our `ADDON_LOADED`. Questie calls it at the end of Stage 3 (`QuestieInit.lua:342-343`), after its tooltip post-calls, quest log and completed set exist.
- The ready callback runs one fail-closed field check, then installs the item-tooltip post-call, the map-icon hooks, the correction hook, the level-range hook and `Questie.API.RegisterForQuestUpdates`, and schedules the item index 5 s later.
- `RegisterForQuestUpdates(fn)` gets `(questId, objectiveIndex, triggerReason)`. `QUEST_UPDATED` only re-renders; accept, turn-in and abandon also invalidate the scan. All go through the 0.5 s debounce. On accept Questie calls back before `QuestLifecycle:AcceptQuest` adds the quest to `currentQuestlog` (`QuestEventHandler.lua:262` then `QuestLifecycle.lua:98`), so the debounce matters.
- Until ready, every launcher prints "Questie has not finished loading yet". If Questie's init aborts, ready never comes and the message stays; there is no polling.
- `Questie.API` itself is checked at `ADDON_LOADED` (`RegisterOnReady`, `RegisterForQuestUpdates`, `Enums.QuestUpdateTriggerReason`).

The fail-closed check (`QUESTIE_FIELDS`) covers every internal the code reads. One missing field prints its name and keeps the window closed for the session. It is per field because `QuestieLoader:ImportModule` returns an empty module, never nil. The fields and where they live in the installed Questie 12.0.3:

- `QuestieDB`: `QuestPointers` (bound at `QuestieDB.lua:467`), `QueryQuestSingle`/`QueryNPCSingle`/`QueryItemSingle`/`QueryObjectSingle`/`QueryQuest` (`:443-447`), `GetNPC` (`:2039`), `GetQuest` (`:1658`), `IsDoable` (`:873`), `IsPreQuestSingleFulfilled` (`:856`), `IsPreQuestGroupFulfilled` (`:821`), `IsRepeatable` (`:656`), `IsComplete` (`:1604`), `IsTrivial` (`:1627`), `GetQuestTagInfo` (`:769`), `autoBlacklist` (`:54`), `RefreshAfterCorrectionApply` (`:523`)
- `QuestieLib` (`Modules/Libs/QuestieLib.lua`): `GetDifficultyColorPercent` (`:71`), `GetColoredQuestName` (`:151`), `GetEffectiveQuestLevel` (`:224`)
- `QuestiePlayer` (`Modules/QuestiePlayer.lua`): `currentQuestlog` (`:15`), `HasRequiredRace` (`:93`), `HasRequiredClass` (`:110`), `GetCurrentZoneId` (`:116`)
- `ZoneDB` (`Database/Zones/zoneDB.lua`): `GetUiMapIdByAreaId` (`:141`), `GetLocalizedDungeonName` (`:209`)
- `QuestXP.GetQuestLogRewardXP` (`QuestieXP.lua:93`), `QuestieMap.GetFramesForQuest` (`QuestieMap.lua:81`), `QuestieCorrections.hiddenQuests` (`QuestieCorrections.lua:28`), `QuestieTooltips.lookupByKey` (`Tooltip.lua:28`), `QuestieFrame.CreateIconFrame` (`QuestieFrame.lua:47`)
- `QuestieCompat.GetQuestGreenRange` (`Modules/QuestieCompat.lua:651`; on Forever it returns `UnitQuestTrivialLevelRange("player")`), `AvailableQuests.ResetLevelRequirementCache` (`Modules/Quest/AvailableQuests/IsLevelRequirementFulfilled.lua:78`)
- `Questie.Colorize` (`Questie.lua:127`), `Questie.LOWLEVEL_ALL` / `_OFFSET` / `_RANGE` (`Questie.lua:339-342`), `Questie.db`, and `Questie.db.char.complete` / `.hidden`
- `Questie.db.profile` (AceDB, so unset keys read their default): `lowLevelStyle`, `manualLevelOffset`, `minLevelFilter`, `maxLevelFilter` (`Modules/Options/QuestieOptionsDefaults.lua:123-126`), and `enableTooltips`, `enableTooltipsQuestLevel`, `showQuestsInNpcTooltip` (`:56`, `:62`, `:162`), which the item tooltip already read without being checked

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
| Grey / green range | `UnitQuestTrivialLevelRange("player")` | Sliders: `QuestieDB.IsTrivial` for grey, QuestieLib's red tier (+5). "Use Questie Level Ranges": Questie's own Quest Level Options, see below |
| "Is in the quest log" before opening the log | `C_QuestLog.GetLogIndexForQuestID` | `QuestiePlayer.currentQuestlog` |
| Quest change events | `QUEST_ACCEPTED`, `QUEST_REMOVED`, `QUEST_TURNED_IN`, `UNIT_QUEST_LOG_CHANGED` | `Questie.API.RegisterForQuestUpdates` |

Already from Questie and unchanged: quest log contents, names, levels (`GetEffectiveQuestLevel`), difficulty colours, objectives, XP, tags, givers and turn-ins, zones, prerequisites, race/class gates, hidden and blacklisted quests, completeness of log quests.

### "Use Questie Level Ranges" (owner decision, round 2)

The checkbox follows the range the player set in Questie's **Quest Level Options** (Questie options > General), the same bounds Questie's available-quest pins use. Before, it applied Questie's yellow/green colour tiers.

Questie's rule in the installed 12.0.3:

- Bounds, computed in `_CalculateAndDrawAvailableQuests` (`AvailableQuests.lua:576-585`): `minLevel = playerLevel - GetQuestGreenRange`, `maxLevel = playerLevel`. Style `LOWLEVEL_RANGE` (4) replaces both with `minLevelFilter` / `maxLevelFilter`; `LOWLEVEL_OFFSET` (3) sets `minLevel = playerLevel - manualLevelOffset`. `LOWLEVEL_NONE` (1, default) and `LOWLEVEL_ALL` (2) keep the defaults.
- Test, `AvailableQuests.IsLevelRequirementsFulfilled` (`IsLevelRequirementFulfilled.lua:21-75`): at or under `maxLevel`, the quest fails when its level is under `minLevel`, except in `LOWLEVEL_ALL`. Above `maxLevel`, it fails in `LOWLEVEL_RANGE`, or when `requiredLevel > maxLevel`. Then `requiredLevel > maxLevel` fails, and so does outliving `requiredMaxLevel`.

How the guide applies it (`getQuestieLevelBounds`, `isInQuestieRange`):

- The quest-level half is mirrored exactly. Under the checkbox it replaces both the slider band (`passesPlayerBand`) and the grey cut (`isLevelExcluded`). So "show all low level quests" and a large offset list grey quests, and red quests with a met required level count toward XP like any in-range quest.
- The required-level half stays the guide's own gates, `meetsRequiredLevel` (player level) and `exceedsRequiredMaxLevel`. They equal Questie's except in `LOWLEVEL_RANGE` with `maxLevelFilter` above the player: Questie then pins quests the player can't accept yet, and the guide keeps them out because its rows say Available. The follow-up projection still skips the required-level gate, as before.
- Not mirrored: Questie's two exceptions ahead of the test. It keeps a quest whose parent quest is in the log (`:28-33`). Outside `LOWLEVEL_RANGE` it also keeps an active event quest whose required level is under `minLevel` (`:35-39`, `QuestieEvent.activeQuests`). See the open questions.
- Questie calls `AvailableQuests.ResetLevelRequirementCache` on every change to these options (`QuestieOptionsGeneral.lua:369-438`, the Questie menu's "Trivial Quest" toggle at `QuestieMenu.lua:346-352`) and on level-up (`EventHandler.lua:463`). The guide post-hooks it (`hooksecurefunc`, installed at ready) and rescans while the checkbox is on. Every caller reads the field at call time, so the hook sees them all. The guide never calls `IsLevelRequirementsFulfilled` itself, because that fills Questie's per-quest cache.

Native calls that stay, and why:

- `C_Map.GetAreaInfo(areaId)`: the zone name for a Questie area id. Questie resolves names the same way (`TrackerUtils:GetZoneNameByID` and `ZoneDB:GetLocalizedDungeonName` both call it first); `ZoneDB:GetLocalizedDungeonName` is the fallback here too.
- `UnitLevel`, `UnitXPMax`, `GetMaxPlayerLevel`, `UnitFactionGroup` ("player"): the player's own level, XP, level cap and faction, not quest data. Questie's own `_AddStarter` and `QuestXP` read the same calls.
- `QuestMapFrame_OpenToQuestDetails`: opens Blizzard's quest log.
- `OpenWorldMap`, `C_Map.GetMapArtLayers`, `C_Map.GetMapInfo`, `WorldMapFrame:GetMapID`: the map jump.
- `C_Map.CanSetUserWaypointOnMap`, `C_Map.SetUserWaypoint`, `UiMapPoint.CreateFromCoordinates`, `C_SuperTrack.SetSuperTrackedUserWaypoint`: the waypoint.
- `TooltipDataProcessor.AddTooltipPostCall` with `data.id`: which item a tooltip shows.
- `C_QuestLog.IsEliteQuest(questID)` (deliberate, owner decision round 2): the elite flag behind the Elite (Group) tag. Questie has no elite status. Its `questTagIds.ELITE` is tag 1, which Forever names Group. `QuestieCompat.GetQuestTagInfo` returns the client's `isElite`, but `QuestieDB.GetQuestTagInfo`, the cached and corrected wrapper, keeps only id and name (`QuestieDB.lua:769-795`). Verified on Forever: `QuestLogDocumentation.lua:749-761` (one `questID` number, returns a non-nilable bool), `GlobalAPI.lua:3584`, and Camelot's own quest log marks elites with it (`Blizzard_UIPanels_Game/Camelot/QuestMapFrameOverrides.lua:15-21`, a loaded file). Called uncached on each tag lookup, so a quest whose data arrives later is right on the next render.
- `ChatFrameUtil.GetActiveWindow` / `InsertLink` / `OpenChat`: chat links.
- Events `PLAYER_LEVEL_UP` (payload level) and `ZONE_CHANGED_NEW_AREA`: the player's level and location.

Questie calls that wrap natives: `QuestieDB.GetQuestTagInfo` (C_QuestLog.GetQuestTagInfo plus Questie's tag corrections and cache), `QuestieDB.IsComplete` (Questie's quest log cache), `QuestieDB.IsTrivial` (UnitQuestTrivialLevelRange via QuestieCompat), `QuestiePlayer:GetCurrentZoneId` (C_Map.GetBestMapForUnit plus ZoneDB).

## Native UI

- The window is `ButtonFrameTemplate` (`QuestieGuideFrame`), strata HIGH, toplevel, clamped, movable, portrait from the toc icon, title "Questie Guide", Escape via `UISpecialFrames`, built lazily. One toggle (`toggleIfReady`) serves `/qg`, the key binding, the minimap button and the compartment.
- Layout follows ChannelFrame: settings column in an `InsetFrameTemplate`, the list in the template's `.Inset`, both placed with `PANEL_INSET_*`. The search box (`SearchBoxTemplate`) sits in the attic like AddonList's.
- The list uses `ScrollFrameTemplate` (MinimalScrollBar); the gutter comes from the real bar width plus `SCROLL_FRAME_SCROLL_BAR_OFFSET_LEFT`, and `SCROLL_FRAME_SCROLL_BAR_OFFSET_TOP` (2) keeps the bar inside the inset.
- Fixed size 680x620 (owner decision round 2): no resize grip, no saved size, `/qg reset` only recentres. Position still persists (`framePos`). An old `frameSize` key in existing SavedVariables stays unread.
- Bottom bar: two `MagicButtonTemplate` buttons. The primary, Current Zone, sits at BOTTOMRIGHT; Collapse All is anchored RIGHT to its LEFT. Both use zero offsets, then `MagicButton_OnLoad`, which applies -6/4 at the corner and -1 to the neighbour (`SharedUIPanelTemplates.lua:12-46`). Left to right they read Collapse All, Current Zone, as before.
- Controls: `WowStyle1DropdownTemplate`, `MinimalSliderWithSteppersTemplate`, `UICheckButtonTemplate` (`.Text`), `UIPanelButtonTemplate` for the empty-state action, `MenuUtil.CreateContextMenu`.
- Row art from Forever's quest UI: hover `Interface\QuestFrame\UI-QuestTitleHighlight` (Forever's GossipFrame and quest greeting rows), selection atlas `questlog-quest-glow-yellow` (the called-out quest in Forever's quest log, `QuestMapFrame.xml:227`, `QuestMapFrame.lua:1956`), header toggles `UI-PlusButton-Up` / `UI-MinusButton-Up` / `UI-PlusButton-Hilight` (Forever's Group Finder listing, `Blizzard_LFGVanilla_Listing.lua:956-958`).
- Colours are Blizzard colour objects (`GRAY`, `NORMAL`, `YELLOW`, `LIGHTBLUE`, `GREEN`, `ORANGE`, `LINK`, `RED`, `HIGHLIGHT` `_FONT_COLOR`, `EPIC_PURPLE_COLOR`) and `QuestDifficultyColors.header` for header grey (Blizzard's own quest-header colour, a plain `{r, g, b}` table in `Blizzard_FrameXMLBase/Constants.lua:201`). No literal `|cff` codes. The Elite (Group) tag is `NORMAL_FONT_COLOR`, the gold `GameFontNormal` Forever's quest log uses for its "(Elite)" tag (`QuestMapFrame.xml:215`). Owner-approved exceptions: level and name colours are Questie's difficulty colour (`CreateColor` of `GetDifficultyColorPercent`), and item-tooltip status suffixes use `Questie:Colorize` so they match Questie's own lines above them.
- Chat: every line starts with `YELLOW_FONT_COLOR:WrapTextInColorCode("[Questie Guide]:") .. " "`, the prefix all the author's addons share.
- Fonts: Blizzard font objects only. Tooltips: the `GameTooltip_*` helpers.
- Minimap button: LibDBIcon with an LDB launcher "Questie Guide", icon = toc icon, db at `QuestieGuideDB.minimap`.

Forever facts:

- `OpenWorldMap(mapID)` exists and honours the WorldMapDisabled game rule (`Blizzard_WorldMap.lua:1408-1414`).
- `Enum.QuestTag` 1 is Group (`LuaEnum.lua:6714`, group icon at `Blizzard_FrameXMLBase/Constants.lua:527`). Camelot marks elites with `C_QuestLog.IsEliteQuest` (`Camelot/QuestMapFrameOverrides.lua:15-21`), which Questie doesn't expose. Its quest log shows the elite text and the type icon side by side (`Mainline/QuestMapFrame.lua:1833-1858`). The guide has one tag per row, so Dungeon, Raid and PvP keep their label and an elite quest otherwise reads Elite (Group).
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
| QG-12 | TomTom branch | Removed (owner decision round 2): the branch in `openMapForQuest`, the README line and the checklist wording. The native waypoint is the only path |
| QG-13 | Animation probes | Direct `SetScaleFrom/To` and `SetFromAlpha/ToAlpha`; one pulse helper |
| QG-14 | `ShowUIPanel(WorldMapFrame)` plus guards | `OpenWorldMap(renderMapId)` |
| QG-15 | Redundant guards, `formatNumber`, defaults twice | Guards removed, `BreakUpLargeNumbers`, defaults only in `DEFAULTS` |
| QG-16 | Tag 1 labelled Elite | Relabelled Group (settled by the Forever source). Round 2 (owner decision): elite quests from `C_QuestLog.IsEliteQuest` are tagged Elite (Group) and join the Elite (Group) filter with Group and Raid |
| QG-17 | Era and both-client comments | Rewritten |
| QG-18 | Era README | Forever only |
| QG-19 | toc metadata | `## Category: Quests`, `## RequiredDeps: Questie`, one icon path, 2.0.0 |
| QG-20 | Near Lua 5.1 limits | Main chunk 134 active locals after round 2 (single-use helpers in `do` blocks), `renderList` 48 upvalues. Estimated from luac 5.5; no 5.1 compiler here |
| QG-21 | Caches survive a correction | Post-hook on `QuestieDB.RefreshAfterCorrectionApply`: NPC, object and quest writes clear the giver, turn-in and reachability caches and rescan; quest writes also drop the follower index and rebuild the item index; item-name repairs are ignored |
| QG-22 | `wtqPulse` / `_wtqCount` on Questie's frames | `qgPulse` / `qgLoops` |

## Owner decisions, round 2 (2026-09-30, inside 2.0.0)

| Decision | Done |
|---|---|
| Remove TomTom completely | Branch, README line and checklist wording gone (QG-12). The map-pin hook comment now calls Questie's own Ctrl-click "Ctrl waypoint" |
| Elite quests tagged Elite (Group) | `getQuestTagLabel` asks `C_QuestLog.IsEliteQuest` when Questie's tag is empty or Group. The Elite (Group) filter covers Elite (Group), Group and Raid. The tag is gold (`NORMAL_FONT_COLOR`) |
| "Use Questie Level Ranges" follows Questie's options | `getQuestieLevelBounds` and `isInQuestieRange` mirror Questie's bounds and quest-level test. The ranges hook rescans on option changes. Seven `Questie.db.profile` keys, three `Questie.LOWLEVEL_*` constants, `QuestieCompat.GetQuestGreenRange` and `AvailableQuests.ResetLevelRequirementCache` joined the fail-closed check |
| Remove resizing, primary action bottom-right | `PanelResizeButtonTemplate`, `SetResizable`/`SetResizeBounds`, `DEFAULTS.frameSize` and the size half of `/qg reset` gone. Window fixed at 680x620. Current Zone at BOTTOMRIGHT, Collapse All to its left |
| Colour objects and shared chat prefix | Already free of literal colour codes. The prefix is now written as the shared convention (`YELLOW_FONT_COLOR:WrapTextInColorCode(...)`) instead of through a one-use `COLOR.PREFIX` alias |

## Open items

Owner questions raised by the round-2 decisions:

1. Elite plus another tag: an elite quest that Questie tags Dungeon, Raid or PvP keeps that label (a Dungeon one stays under the Dungeons filter). Keep: no change. Elite wins: drop the `not label or label == "Group"` condition (1 line), and elite dungeon quests move to the Elite (Group) filter. Both: show two tags, and the row passes only when both filters are on (about 10 lines).
2. Red quests under Questie's range: Questie's range has no upper colour tier, so red quests with a met required level now count toward the XP figures when the checkbox is on. Keep: no change. Keep red out of XP in both modes: add the red test to the Questie branch of `passesPlayerBand` (1 line), which also hides those rows as out of range.
3. Questie's "between two set levels" with a top above your level: Questie pins quests you can't accept yet (grey !), and the guide keeps them out. Keep: no change. Show them: let `meetsRequiredLevel` use `maxLevelFilter` in that style, and give those rows their own label instead of [Available] (about 15 lines).
4. Questie's two exceptions (parent quest in the log; active event quests under the bottom, outside the range style): not mirrored. Keep: no change. Mirror them: pass the quest id and required levels into the band, and add `QuestieEvent.activeQuests` to the fail-closed check (about 15 lines).

Robustness notes (not changed):

- QG-23 (fixed after the main commit): `QuestiePlayer:GetCurrentZoneId()` can raise through `ZoneDB:GetAreaIdByUiMapId` when a map has no area id (`zoneDB.lua:152-174`), and `renderList` calls it every render. `getCurrentZoneName` now runs it in `pcall` and treats a failure as "zone unknown".
- The dungeon-map art walk (`resolveRenderableMapId`) came from Era, where art-less maps crashed the map canvas. Unverified on Forever; kept as a harmless guard.

Unverified:

- The `questlog-quest-glow-yellow` atlas and the plus/minus textures at our row sizes (stretched with `SetAllPoints`, toggles forced to 16x16).
- Whether opening the modern world map and quest log from addon code taints `WorldMapFrame` in combat.
- Whether the waypoint sits on the NPC. Setting it replaces the player's own waypoint.
- Whether the SavedVariables loss on a cold start, reported for an older beta, still happens on 70009.
- The fixed 680x620 window on small screens or at a high UI scale (it is clamped to the screen).
- Whether `C_QuestLog.IsEliteQuest` answers for quests that are not in the log. Blizzard only calls it on log quests. If it returns false until the client has the quest's data, those rows lack the tag until a later render.

## Forever test checklist

Run `/console scriptErrors 1` first.

- [ ] `/reload`: no errors and no "Questie has no …" line. `/qg` before Questie is ready says it's still loading; after it opens.
- [ ] The window: portrait, strata over other panels, settings column left, list right, search top right, Current Zone bottom-right with Collapse All to its left, no resize grip. Fixed 680x620; the position survives `/reload`, and `/qg reset` recentres it. Escape closes it.
- [ ] The dropdowns and sliders work. Search filters the list and the clear button resets it.
- [ ] "Use Questie Level Ranges": with each of Questie's four Quest Level Options styles (and the Questie menu's "Trivial Quest" toggle), the list changes with the window open, and matches the "!" pins Questie draws, apart from quests you can't accept yet.
- [ ] Clicking an Available quest opens the map at the giver, with the Questie pin pulsing. Clicking a Missing Pre-Quest row jumps to the prerequisite. The selected row shows the quest-log glow.
- [ ] Right-click → "Link in chat" inserts the link. A Questie map-icon click opens the guide, except while a chat box is open.
- [ ] Quest items in bags show their status line once, under Questie's lines. The first hover of a quest-start item doesn't show "(Available)" twice (QG-05).
- [ ] The compartment lists Questie Guide; the minimap button tooltip shows the zone count after the first scan.
- [ ] An Available quest sets the native pin and beacon. `/dump C_Map.HasUserWaypoint(), C_SuperTrack.IsSuperTrackingUserWaypoint()` prints `true true`, and the pin sits on the NPC.
- [ ] An In Questlog row opens the quest map log on that quest.
- [ ] Accept a quest with the guide open: within a second the row flips to [In Questlog] (QG-07). Turn one in and abandon one: the list updates. Complete an objective: the Completed section updates.
- [ ] Time the first open and a level-up rescan (QG-10).
- [ ] `/dump GetMaxPlayerLevel(), UnitQuestTrivialLevelRange("player")` (QG-09).
- [ ] Elite: for a known elite quest, `/dump C_QuestLog.GetQuestTagInfo(id), C_QuestLog.IsEliteQuest(id)` once before accepting it and once after. Its row shows [Elite (Group)], and the Elite (Group) filter hides it together with Group quests.
- [ ] Open the guide in combat and click a row: no "action blocked".
- [ ] Fully quit and restart: filters and position survive.
- [ ] Open the guide in every Forever-only zone and instance you reach: no error from `GetCurrentZoneId` (QG-23).
