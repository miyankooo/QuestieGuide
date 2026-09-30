# QuestieGuide — Memory

Updated 2026-09-30 after the Forever-only rework (2.0.0) the owner's round-2 decisions (TomTom, elite quests, Questie level ranges, fixed window size, colours) and round-3 answers (both tags, XP only from green/yellow/orange, level-locked quests, Questie's two range exceptions), all still inside 2.0.0, which has not shipped. The owner's decision: WoW Forever 1.60.x only. `main` holds only the Forever version; `1.15.x-backup` keeps the Classic version. Quest data comes only from Questie.

Verified against:

- Gethe `forever` @ `966519cf` (1.60.1.70124), only files the Forever client loads
- Ketho `forever` @ `4149af64` (1.60.1.70009)
- the installed Questie 12.0.3 (`Questie_Camelot.toc`) with QuestieDB 1.0.4 (Forever flavor, baked)
- the installed client 1.60.1.70009

Nothing has run in a client.

## Current state

Lists every quest you can pick up now, grouped by zone, from Questie's database. On top of that list it adds:

- Trip XP including follow-ups, and a "Next:" banner.
- Status labels (In Questlog, Available, Requires Level N, Missing Pre-Quest, Completed) and a chain tooltip that jumps to the step you can do.
- A map jump to the quest giver with the native user waypoint and beacon.
- Quest type tags (Elite (Group), Group, Dungeon, Raid, PvP), filters, sorting, a completed-quests section, item-tooltip lines and a level-up toast.
- A minimap button, the Addon Compartment, `/qg`, a key binding, and click-through from Questie's map icons.

| Item | State |
|---|---|
| Version | 2.0.0: `## Interface: 16001`, `## Category: Quests`, `## RequiredDeps: Questie`, `## IconTexture: Interface\Icons\INV_Misc_Map02`, Addon Compartment fields |
| Files | One Lua file (`QuestieGuide.lua`, 3,328 lines; 3,219 after the split, 3,557 before it), `Bindings.xml`, the toc, and the four tracked libs in `Libs/` (LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0) |
| Git | `1.15.x-backup` = `origin/1.15.x-backup` = `c50c068` (the dual-client 1.1.0, created by the lead). `main` carries the 2.0.0 commits, not pushed |
| Offline checks | `luac -p` passes (5.5). Lua 5.1 limits estimated from the luac 5.5 listing: main chunk at most 140 active locals (limit 200), `renderList` 49 upvalues, `scanQuestsByZone` 24 (limit 60). The lead's throwaway smoke harness (mocked WoW API and fake Questie, kept in the session scratchpad, not in the repo) passes 76/76. It covers both tags and both filters, zone XP with red, grey and level-locked quests present, `[Requires Level N]` rows and the chain badge, all four Questie level styles, both Questie exceptions, the bar anchors and the missing-field path for the profile, `activeQuests` and `parentQuest`. Every new check was confirmed to fail when its code is removed. A slider-mode diff against `7cfb487` (16 below/above settings, same mock data) renders identical rows; the only difference is that a grey in-log quest inside a wide band no longer adds XP |

## How it talks to Questie

Readiness and refresh use Questie's public API (`Questie/Public/`), which Questie calls stable:

- `Questie.API.RegisterOnReady(fn)` is registered at our `ADDON_LOADED`. Questie calls it at the end of Stage 3 (`QuestieInit.lua:342-343`), after its tooltip post-calls, quest log and completed set exist.
- The ready callback runs one fail-closed field check, then installs the item-tooltip post-call, the map-icon hooks, the correction hook, the level-range hook and `Questie.API.RegisterForQuestUpdates`, and schedules the item index 5 s later.
- `RegisterForQuestUpdates(fn)` gets `(questId, objectiveIndex, triggerReason)`. `QUEST_UPDATED` only re-renders; accept, turn-in and abandon also invalidate the scan. All go through the 0.5 s debounce. On accept Questie calls back before `QuestLifecycle:AcceptQuest` adds the quest to `currentQuestlog` (`QuestEventHandler.lua:262` then `QuestLifecycle.lua:98`), so the debounce matters.
- Until ready, every launcher prints "Questie has not finished loading yet". If Questie's init aborts, ready never comes and the message stays; there is no polling.
- `Questie.API` itself is checked at `ADDON_LOADED` (`RegisterOnReady`, `RegisterForQuestUpdates`, `Enums.QuestUpdateTriggerReason`).

The fail-closed check (`QUESTIE_FIELDS`) covers every internal the code reads. Owners are dotted paths walked from the `Questie` global or a `QuestieLoader` module (`getFieldOwner`). One missing field prints its name and keeps the window closed for the session. It is per field because `QuestieLoader:ImportModule` returns an empty module, never nil. The fields and where they live in the installed Questie 12.0.3:

- `QuestieDB`: `QuestPointers` (bound at `QuestieDB.lua:467`), `QueryQuestSingle`/`QueryNPCSingle`/`QueryItemSingle`/`QueryObjectSingle`/`QueryQuest` (`:443-447`), `GetNPC` (`:2039`), `GetQuest` (`:1658`), `IsDoable` (`:873`), `IsPreQuestSingleFulfilled` (`:856`), `IsPreQuestGroupFulfilled` (`:821`), `IsRepeatable` (`:656`), `IsComplete` (`:1604`), `IsTrivial` (`:1627`), `GetQuestTagInfo` (`:769`), `autoBlacklist` (`:54`), `RefreshAfterCorrectionApply` (`:523`)
- `QuestieLib` (`Modules/Libs/QuestieLib.lua`): `GetDifficultyColorPercent` (`:71`), `GetColoredQuestName` (`:151`), `GetEffectiveQuestLevel` (`:224`)
- `QuestiePlayer` (`Modules/QuestiePlayer.lua`): `currentQuestlog` (`:15`), `HasRequiredRace` (`:93`), `HasRequiredClass` (`:110`), `GetCurrentZoneId` (`:116`)
- `ZoneDB` (`Database/Zones/zoneDB.lua`): `GetUiMapIdByAreaId` (`:141`), `GetLocalizedDungeonName` (`:209`)
- `QuestXP.GetQuestLogRewardXP` (`QuestieXP.lua:93`), `QuestieMap.GetFramesForQuest` (`QuestieMap.lua:81`), `QuestieCorrections.hiddenQuests` (`QuestieCorrections.lua:28`), `QuestieTooltips.lookupByKey` (`Tooltip.lua:28`), `QuestieFrame.CreateIconFrame` (`QuestieFrame.lua:47`)
- `QuestieCompat.GetQuestGreenRange` (`Modules/QuestieCompat.lua:651`; on Forever it returns `UnitQuestTrivialLevelRange("player")`), `AvailableQuests.ResetLevelRequirementCache` (`Modules/Quest/AvailableQuests/IsLevelRequirementFulfilled.lua:78`), `QuestieEvent.activeQuests` (`Database/Corrections/Holidays/QuestieEvent.lua:73`, filled in place, read through its module)
- `QuestieDB.questKeys.parentQuest`: the key enum Questie binds at file load from the provider (`QuestieDB.lua:432-440`; `parentQuest = 25` in `QuestieDB/src/meta/questMeta.lua:69`). It is the only query key the check covers; the other key names the guide queries are unchecked
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
| Grey / green range | `UnitQuestTrivialLevelRange("player")` | Listing: sliders drop `QuestieDB.IsTrivial` grey and QuestieLib's red tier (+5); "Use Questie Level Ranges" follows Questie's own Quest Level Options, see below. XP: `QuestieDB.IsTrivial` and the red tier in both modes |
| "Is in the quest log" before opening the log | `C_QuestLog.GetLogIndexForQuestID` | `QuestiePlayer.currentQuestlog` |
| Quest change events | `QUEST_ACCEPTED`, `QUEST_REMOVED`, `QUEST_TURNED_IN`, `UNIT_QUEST_LOG_CHANGED` | `Questie.API.RegisterForQuestUpdates` |

Already from Questie and unchanged: quest log contents, names, levels (`GetEffectiveQuestLevel`), difficulty colours, objectives, XP, tags, givers and turn-ins, zones, prerequisites, race/class gates, hidden and blacklisted quests, completeness of log quests.

### "Use Questie Level Ranges" (owner decision, round 2)

The checkbox follows the range the player set in Questie's **Quest Level Options** (Questie options > General), the same bounds Questie's available-quest pins use. Before, it applied Questie's yellow/green colour tiers.

Questie's rule in the installed 12.0.3:

- Bounds, computed in `_CalculateAndDrawAvailableQuests` (`AvailableQuests.lua:576-585`): `minLevel = playerLevel - GetQuestGreenRange`, `maxLevel = playerLevel`. Style `LOWLEVEL_RANGE` (4) replaces both with `minLevelFilter` / `maxLevelFilter`; `LOWLEVEL_OFFSET` (3) sets `minLevel = playerLevel - manualLevelOffset`. `LOWLEVEL_NONE` (1, default) and `LOWLEVEL_ALL` (2) keep the defaults.
- Test, `AvailableQuests.IsLevelRequirementsFulfilled` (`IsLevelRequirementFulfilled.lua:21-75`): at or under `maxLevel`, the quest fails when its level is under `minLevel`, except in `LOWLEVEL_ALL`. Above `maxLevel`, it fails in `LOWLEVEL_RANGE`, or when `requiredLevel > maxLevel`. Then `requiredLevel > maxLevel` fails, and so does outliving `requiredMaxLevel`.

How the guide applies it (`getQuestieLevelBounds`, `isInQuestieRange`, `getRequiredLevelCap`, `isQuestieRangeException`):

- The quest-level half is mirrored exactly. Under the checkbox it replaces both the slider band (`passesPlayerBand`) and the grey cut (`isLevelExcluded`). So "show all low level quests" and a large offset list grey quests, and red quests with a met required level list too. None of them add XP (see "XP counting").
- The required-level half is mirrored too (round 3): the listing cap is `getRequiredLevelCap`, which is Questie's `maxLevel`. That is the player's level in every style except `LOWLEVEL_RANGE`, where it is `maxLevelFilter` (`IsLevelRequirementFulfilled.lua:61`). Two consequences:
  - A top below the player now also drops quests whose required level is above it, as Questie does.
  - A top above the player lets quests through that the player can't accept yet. Questie pins those with the same grey "!" it uses for trivial quests (`QuestieLib.GetQuestIcon`, `QuestieLib.lua:779-780`). Its own comment calls them "not available yet due to level restrictions" (`AvailableQuests.lua:883-888`), and its Journey panel labels the field "Required Level" (`QuestDetailsFrame.lua:339`).
- The guide lists those quests (`lockedLevel` on the row) as `[Requires Level N]`, in Blizzard's own `ITEM_MIN_LEVEL` wording ("Requires Level %d", `GlobalStrings_enUS.lua:12726`), grey like Questie's pin, on a row dimmed to 0.5 like Missing Pre-Quest rows. They sort with blocked rows and count in the header quest count. They never add XP, never seed the follow-up projection and stay out of the average level. A click opens the map at the giver. The chain tooltip shows the same badge for a prior step whose only obstacle is its level (`IsDoable` ignores levels).
- Only doable quests get a `[Requires Level N]` row. Prerequisite-blocked quests still need the player's own level, and Questie doesn't pin non-doable quests either. `exceedsRequiredMaxLevel` stays the guide's gate. The follow-up projection still skips the required-level gate, as before.
- Questie's two exceptions ahead of the test are mirrored too (owner decision, round 3), in `isQuestieRangeException`, only under the checkbox:
  - A quest whose `parentQuest` is in `QuestiePlayer.currentQuestlog` is always in range (`:28-33`).
  - Outside `LOWLEVEL_RANGE`, an active event quest (`QuestieEvent.activeQuests`) whose required level is under `minLevel` is in range while the player is under its `requiredMaxLevel`, or it has none (`:35-39`).
  - As in Questie, where the early return skips the whole test, an exception waives the band, `isLevelExcluded` and the required-level cap, in the discovery scan (`passesListingGates`, `passesLevelGate`), the follow-up projection (`isFollowerInRange`) and the log rows' out-of-range flag.
  - One difference is kept: `exceedsRequiredMaxLevel` still drops a child quest the player has outlevelled, because such a row would say Available for a quest that can never be accepted. A child whose required level is above the player lists as `[Requires Level N]`.
  - The event lookup runs first; the parent query only runs for quests that fail the normal gates, and only under the checkbox.
- Questie calls `AvailableQuests.ResetLevelRequirementCache` on every change to these options (`QuestieOptionsGeneral.lua:369-438`, the Questie menu's "Trivial Quest" toggle at `QuestieMenu.lua:346-352`) and on level-up (`EventHandler.lua:463`). The guide post-hooks it (`hooksecurefunc`, installed at ready) and rescans while the checkbox is on. Every caller reads the field at call time, so the hook sees them all. The guide never calls `IsLevelRequirementsFulfilled` itself, because that fills Questie's per-quest cache.

### XP counting (owner answer, round 3)

`countsTowardXp(level, playerLevel)`: only green, yellow and orange quests add XP, in both modes. That means not `QuestieDB.IsTrivial` and not QuestieLib's red tier (5+ above). Each row carries `countsXp`, set false for level-locked rows. Every XP sum reads it:

- the zone header XP (`renderList` `inRangeXp`)
- the one-trip `stats.xp` (`xpNow`), which drives the XP sort, the best zone and the Next banner
- the follow-up XP and count (`collectZoneFollowups`)
- the "gated outside this zone" travel XP and count

Grey and red followers still join the projection (`ids`, frontier), so their own followers and the blocked rows' `unlocksHere` resolve as before. Row colours are unchanged (Questie's difficulty colour). Quest counts (header "(N)", `stats.count`, the Total Quest Count sort and the launcher tooltip) still count every listed in-range row. The sliders still never list red quests; Questie's range lists them when Questie does.

### The guide's own range (checkbox off)

Unchanged by rounds 2 and 3 except for the XP rule:

- A quest outside the log is listed when it passes the level cap and `meetsRequiredLevel` (player level). It must not have outlived its `requiredMaxLevel`, must not be grey (`QuestieDB.IsTrivial`), and needs a reachable starter.
- It is in range (`outOfRange` false) when its level sits in [player - below, player + above] and it isn't red. Out-of-range non-log quests don't render; log quests always render.
- Questie's Quest Level Options, its two exceptions, `[Requires Level N]` rows and the level-cache hook (`onQuestieLevelRangeChanged` returns early) never apply here.
- XP: in-range green, yellow and orange quests only. The one visible change is that a grey in-log quest inside a wide band (below 10) no longer adds its reduced XP.

Native calls that stay, and why:

- `C_Map.GetAreaInfo(areaId)`: the zone name for a Questie area id. Questie resolves names the same way (`TrackerUtils:GetZoneNameByID` and `ZoneDB:GetLocalizedDungeonName` both call it first); `ZoneDB:GetLocalizedDungeonName` is the fallback here too.
- `UnitLevel`, `UnitXPMax`, `GetMaxPlayerLevel`, `UnitFactionGroup` ("player"): the player's own level, XP, level cap and faction, not quest data. Questie's own `_AddStarter` and `QuestXP` read the same calls.
- `QuestMapFrame_OpenToQuestDetails`: opens Blizzard's quest log.
- `OpenWorldMap`, `C_Map.GetMapArtLayers`, `C_Map.GetMapInfo`, `WorldMapFrame:GetMapID`: the map jump.
- `C_Map.CanSetUserWaypointOnMap`, `C_Map.SetUserWaypoint`, `UiMapPoint.CreateFromCoordinates`, `C_SuperTrack.SetSuperTrackedUserWaypoint`: the waypoint.
- `TooltipDataProcessor.AddTooltipPostCall` with `data.id`: which item a tooltip shows.
- `ITEM_MIN_LEVEL` (global string, not a call): the `[Requires Level N]` wording.
- `C_QuestLog.IsEliteQuest(questID)` (deliberate, owner decision round 2): the elite flag behind the Elite (Group) tag. Questie has no elite status. Its `questTagIds.ELITE` is tag 1, which Forever names Group. `QuestieCompat.GetQuestTagInfo` returns the client's `isElite`, but `QuestieDB.GetQuestTagInfo`, the cached and corrected wrapper, keeps only id and name (`QuestieDB.lua:769-795`). Verified on Forever: `QuestLogDocumentation.lua:749-761` (one `questID` number, returns a non-nilable bool), `GlobalAPI.lua:3584`, and Camelot's own quest log marks elites with it (`Blizzard_UIPanels_Game/Camelot/QuestMapFrameOverrides.lua:15-21`, a loaded file). Called uncached on each tag lookup, so a quest whose data arrives later is right on the next render. An elite quest that Questie tags Dungeon, Raid or PvP carries both tags (round 3); a Group-tagged elite shows only Elite (Group), which already says group.
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
- Colours are Blizzard colour objects (`GRAY`, `NORMAL`, `YELLOW`, `LIGHTBLUE`, `GREEN`, `ORANGE`, `LINK`, `RED`, `HIGHLIGHT` `_FONT_COLOR`, `EPIC_PURPLE_COLOR`) and `QuestDifficultyColors.header` for header grey (Blizzard's own quest-header colour, a plain `{r, g, b}` table in `Blizzard_FrameXMLBase/Constants.lua:201`). No literal `|cff` codes. The Elite (Group) tag is `NORMAL_FONT_COLOR`, the gold `GameFontNormal` Forever's quest log uses for its "(Elite)" tag (`QuestMapFrame.xml:215`). `[Requires Level N]` is `GRAY_FONT_COLOR`, like Questie's grey "!" pin. Owner-approved exceptions: level and name colours are Questie's difficulty colour (`CreateColor` of `GetDifficultyColorPercent`), and item-tooltip status suffixes use `Questie:Colorize` so they match Questie's own lines above them.
- Chat: every line starts with `YELLOW_FONT_COLOR:WrapTextInColorCode("[Questie Guide]:") .. " "`, the prefix all the author's addons share.
- Fonts: Blizzard font objects only. Tooltips: the `GameTooltip_*` helpers.
- Minimap button: LibDBIcon with an LDB launcher "Questie Guide", icon = toc icon, db at `QuestieGuideDB.minimap`.

Forever facts:

- `OpenWorldMap(mapID)` exists and honours the WorldMapDisabled game rule (`Blizzard_WorldMap.lua:1408-1414`).
- `Enum.QuestTag` 1 is Group (`LuaEnum.lua:6714`, group icon at `Blizzard_FrameXMLBase/Constants.lua:527`). Camelot marks elites with `C_QuestLog.IsEliteQuest` (`Camelot/QuestMapFrameOverrides.lua:15-21`), which Questie doesn't expose. Its quest log shows the elite text and the type icon side by side (`Mainline/QuestMapFrame.lua:1833-1858`). The guide mirrors that: an elite Dungeon, Raid or PvP quest shows `[Elite (Group)] [Dungeon]` (elite first), and `passesTagFilter` needs every filter covering one of its tags (`TAG_FILTERS`), so an elite dungeon quest hides when either Dungeons or Elite (Group) is off.
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
| QG-20 | Near Lua 5.1 limits | Main chunk 140 active locals after round 3 (single-use helpers in `do` blocks), `renderList` 49 upvalues. Estimated from luac 5.5; no 5.1 compiler here |
| QG-21 | Caches survive a correction | Post-hook on `QuestieDB.RefreshAfterCorrectionApply`: NPC, object and quest writes clear the giver, turn-in and reachability caches and rescan; quest writes also drop the follower index and rebuild the item index; item-name repairs are ignored |
| QG-22 | `wtqPulse` / `_wtqCount` on Questie's frames | `qgPulse` / `qgLoops` |

## Owner decisions, round 2 (2026-09-30, inside 2.0.0)

| Decision | Done |
|---|---|
| Remove TomTom completely | Branch, README line and checklist wording gone (QG-12). The map-pin hook comment now calls Questie's own Ctrl-click "Ctrl waypoint" |
| Elite quests tagged Elite (Group) | `C_QuestLog.IsEliteQuest` adds the tag. The Elite (Group) filter covers Elite (Group), Group and Raid. The tag is gold (`NORMAL_FONT_COLOR`). Round 3 changed how it combines with other tags |
| "Use Questie Level Ranges" follows Questie's options | `getQuestieLevelBounds` and `isInQuestieRange` mirror Questie's bounds and quest-level test. The ranges hook rescans on option changes. Seven `Questie.db.profile` keys, three `Questie.LOWLEVEL_*` constants, `QuestieCompat.GetQuestGreenRange` and `AvailableQuests.ResetLevelRequirementCache` joined the fail-closed check |
| Remove resizing, primary action bottom-right | `PanelResizeButtonTemplate`, `SetResizable`/`SetResizeBounds`, `DEFAULTS.frameSize` and the size half of `/qg reset` gone. Window fixed at 680x620. Current Zone at BOTTOMRIGHT, Collapse All to its left |
| Colour objects and shared chat prefix | Already free of literal colour codes. The prefix is now written as the shared convention (`YELLOW_FONT_COLOR:WrapTextInColorCode(...)`) instead of through a one-use `COLOR.PREFIX` alias |

## Owner answers, round 3 (2026-09-30, inside 2.0.0)

| Answer | Done |
|---|---|
| Elite plus another tag: show both | `getQuestTags` returns elite first plus Questie's Dungeon, Raid or PvP tag. Rows, the quest tooltip and the chain tooltip show every tag. `passesTagFilter` needs every covering filter (`TAG_FILTERS`) |
| XP only from green, yellow and orange quests, both modes | `countsTowardXp` and the per-row `countsXp` gate every XP sum, see "XP counting". Listing is unchanged |
| Show Questie's above-your-level range quests with their own label | `getRequiredLevelCap` and `lockedLevel`; `[Requires Level N]` rows, dimmed, never XP, see the Questie range section |
| Copy Questie's two exceptions under its range | `isQuestieRangeException`; `QuestieEvent.activeQuests` and `QuestieDB.questKeys.parentQuest` joined the fail-closed check. See the Questie range section |
| Primary button | Left as is (Current Zone bottom-right) |
| The guide's own slider mode unchanged | Verified by the slider-mode diff (see Offline checks). It lists exactly what it listed before; the only change is the owner's XP rule, so grey in-log quests inside a wide band no longer add XP |

## Open items

Owner questions still open:

1. Primary button: Current Zone sits bottom-right as the primary action, with Collapse All to its left. Swapping them is two lines in `buildButtonBar`.

New questions raised by the round-3 answers:

2. Quest counts: XP now counts only green, yellow and orange quests. The header count "(N)", the Total Quest Count sort and the launcher tooltip's "N quests available" still count every listed in-range row, grey, red and `[Requires Level N]` included. Keep: no change. Match XP: count only rows with `countsXp` (about 3 lines in the scan and `renderList`).
3. Group-tagged elite quests show only `[Elite (Group)]`, not `[Elite (Group)] [Group]`. Keep: no change. Show both: drop the `label ~= "Group"` test in `getQuestTags` (1 line).
4. Item tooltips still call a quest you are too low for "(Upcoming)", in Questie's `Colorize` style, while the list now says `[Requires Level N]`. Keep: no change. Match: split the item tooltip's level case into "(Requires Level N)" (about 3 lines).
5. Parent exception and `requiredMaxLevel`: Questie's parent-in-log exception also skips its `requiredMaxLevel` test; the guide keeps dropping a child quest the player has outlevelled. Keep: no change. Match Questie: waive `exceedsRequiredMaxLevel` for that exception too (1 line), and such a row would say Available although it can't be accepted.
6. Key check: only `parentQuest` is checked in `QuestieDB.questKeys`. Keep: no change. Check every key the guide queries (about 20 names across quest, NPC, object and item keys): one list per key table in `QUESTIE_FIELDS`.

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
- [ ] "Use Questie Level Ranges": with each of Questie's four Quest Level Options styles (and the Questie menu's "Trivial Quest" toggle), the list changes with the window open and matches the "!" pins Questie draws. With "between two set levels" reaching above your level, Questie's grey "!" quests list dimmed as [Requires Level N].
- [ ] XP: with a red or grey quest listed (Questie's range) and a [Requires Level N] row, the zone header XP, the Next banner and the zone tooltip leave their XP out.
- [ ] Questie's exceptions under "Use Questie Level Ranges": during a holiday, a low-level event quest Questie pins shows in the list. A follow-up whose parent quest is in your log shows even when it is outside the range.
- [ ] Time the first open and a rescan with "Use Questie Level Ranges" on (the parent query runs for every quest outside the range).
- [ ] Clicking an Available quest opens the map at the giver, with the Questie pin pulsing. Clicking a Missing Pre-Quest row jumps to the prerequisite. The selected row shows the quest-log glow.
- [ ] Right-click → "Link in chat" inserts the link. A Questie map-icon click opens the guide, except while a chat box is open.
- [ ] Quest items in bags show their status line once, under Questie's lines. The first hover of a quest-start item doesn't show "(Available)" twice (QG-05).
- [ ] The compartment lists Questie Guide; the minimap button tooltip shows the zone count after the first scan.
- [ ] An Available quest sets the native pin and beacon. `/dump C_Map.HasUserWaypoint(), C_SuperTrack.IsSuperTrackingUserWaypoint()` prints `true true`, and the pin sits on the NPC.
- [ ] An In Questlog row opens the quest map log on that quest.
- [ ] Accept a quest with the guide open: within a second the row flips to [In Questlog] (QG-07). Turn one in and abandon one: the list updates. Complete an objective: the Completed section updates.
- [ ] Time the first open and a level-up rescan (QG-10).
- [ ] `/dump GetMaxPlayerLevel(), UnitQuestTrivialLevelRange("player")` (QG-09).
- [ ] Elite: for a known elite quest, `/dump C_QuestLog.GetQuestTagInfo(id), C_QuestLog.IsEliteQuest(id)` once before accepting it and once after. Its row shows [Elite (Group)], and the Elite (Group) filter hides it together with Group quests. An elite dungeon quest shows [Elite (Group)] [Dungeon] and hides when either filter is off.
- [ ] Open the guide in combat and click a row: no "action blocked".
- [ ] Fully quit and restart: filters and position survive.
- [ ] Open the guide in every Forever-only zone and instance you reach: no error from `GetCurrentZoneId` (QG-23).
