# QuestieGuide

Lists the quests the player can pick up now, grouped by zone and rated by XP, from Questie's data. Features and usage are in `README.md`.

## Target

- WoW Forever 1.60.x only, `## Interface: 16001`. No client branches, no `WOW_PROJECT_*`, no compat layer for other clients or Questie versions.
- `main` holds the Forever version. `1.15.x-backup` keeps the Classic version and stays untouched.
- Verify every API against Gethe `wow-ui-source` and Ketho `BlizzardInterfaceResources`, branch `forever`, in files the Forever client loads. Verify Questie internals against the Questie 12 source.

## Questie

- The one native quest data call is `C_QuestLog.IsEliteQuest`. Questie has no elite flag.
- Tags follow Forever's quest log (Camelot `QuestUtilsOverrides`). A `+` after the level marks `IsEliteQuest`. One tag after the name comes from the tag id with Blizzard globals (`ELITE`, `CALENDAR_TYPE_DUNGEON`, `CALENDAR_TYPE_PVP`, `RAID`). Tags are read at render, never stored in the scan, because Questie's tag cache fills a second after its first miss.
- Never touch LibQuestieDB, so `## Dependencies` stays `Questie` alone.
- Quest types Questie's options hide (`showRepeatableQuests`, `showPvPQuests`, `showDungeonQuests`, `showRaidQuests`, `showAQWarEffortQuests`) never list, mirroring `AvailableQuests._CalculateAndDrawAvailableQuests`. `isFilteredByQuestie` in `Data.lua` is the one check, used by the discovery scan and `isQuestHidden`. Quests already in the log stay.
- Readiness and refresh use only Questie's stable public API, `Questie.API.RegisterOnReady` and `Questie.API.RegisterForQuestUpdates`. No polling, no native quest events.
- Read Questie data only after ready. Hooks into Questie and the item tooltip post-call install from the ready callback. Post-calls run in registration order, so the guide's lines land under Questie's.
- `QUESTIE_FIELDS` lists every Questie internal the code reads. Of the query keys it lists only the newer `parentQuest` and `availableUntilCompleted`. It checks per field, because `QuestieLoader:ImportModule` never returns nil.
- Read fields Questie reassigns through their owner table, never from a cached copy: `QuestPointers`, `currentQuestlog`, `autoBlacklist`, `hiddenQuests`, `Questie.db.char.complete`.
- Clear every cache of Questie data in the `QuestieDB.RefreshAfterCorrectionApply` post-hook. Questie applies corrections after login too.
- Quest updates go through the 0.5 s debounce. On accept, Questie calls back before the quest is in `currentQuestlog`.

## Rules

- The Questie Level Ranges option mirrors Questie's level test without calling `AvailableQuests.IsLevelRequirementsFulfilled`, which fills Questie's per-quest cache. One deliberate difference: an outlevelled quest stays hidden (`exceedsRequiredMaxLevel`).
- The Elite filter hides tag Elite, Raid and every quest with the `IsEliteQuest` `+`. That keeps the old Elite (Group) coverage.
- Every XP sum reads the row's `countsXp`. Zone header counts include every listed in-range row, including grey, red and `[Requires Level N]` rows. The launcher status and the dungeon line count only quests the player can accept now (`countPickable`).
- Rows show a status only for exceptions: `[In Questlog]`, `[Requires Level N]` and `[Missing Pre-Quest]`.
- Every option lives in the attic Filter dropdown (`UI.CreateFilterDropdown`). The sort order is not a filter, so it stays out of the reset. Changes made outside the menu call `ValidateResetState`. Level Range radios return `MenuResponse.Refresh` so the menu stays open. Other radios close it.
- A zone never toggled starts collapsed, except the current zone and the Next zone.
- The map and quest log open through `ShowUIPanel`, which refuses addon callers in combat. Check `InCombatLockdown()` before `OpenWorldMap` and `QuestMapFrame_OpenToQuestDetails`.
- Questie map pin clicks are handled only for `available` pins.
- Zone links in chat (`addon:questieguide:zone:`) go through the `EventRegistry` `SetItemRef` callback. Never hook `SetItemRef`.
- The launcher tooltip and the dungeon line read the last scan (`scanCache.byZone`), even a stale one. They never start one. Only the window scans.
- Left out on purpose: TomTom. The native user waypoint is the only map pin.
- The UI is built from LibNativeUI-1.0: `UI.Font` roles, `UI.Space`, the 4 px grid and `UI.Print`. Off-grid values are named native geometry.
- Colours come from `UI.Color` roles or Blizzard colour objects. No literal `|cff` codes. Quest names and levels use Questie's difficulty colour. Item tooltip suffixes use `Questie:Colorize`.
- The window has a fixed 680x624 size and no resize grip. Current Zone is the primary button, bottom right. Keep the minimap icon, hideable with `/qg minimap`. No options page.
- Title Case for buttons, headings and menu entries. Sentence case ending with a period for tooltips and chat. No em or en dashes. No chat line at login.
- No `## AddonCompartmentFunc*` toc lines. LibDBIcon adds the addon menu entry. Both would list the addon twice.

## Libraries

- `Libs/` holds tracked, unedited upstream copies. LibDBIcon-1.0, LibDataBroker-1.1 and CallbackHandler-1.0 stay for `UI.CreateLauncher` and load before LibNativeUI-1.0.
- LibNativeUI-1.0 is a byte-identical copy whose reference copy lives in ChatScan. Its `README.md` is the spec. Never edit it here. `shasum */Libs/LibNativeUI-1.0/LibNativeUI-1.0.lua` must print one hash.

## Files

- One file per job, loaded in toc order: `Core`, `Data`, `Scan`, `Tooltip`, `Map`, `List`, `Window`, `Launcher`, `Events`. Each starts with `local _, ns = ...`. `Events` names the first value for `ADDON_LOADED`.
- A file shares its functions and tables at its end as `ns.name = name`. Later files copy them into locals at their top. A call to a file that loads later goes through `ns` at call time.
- Values that change at runtime live only on `ns`: `ns.mainFrame`, `ns.questieReady`, `ns.missingQuestieField`.

## Checks

- Run `luac -p` on every Lua file and `lua Tests/Smoke.lua` after a change. The smoke test loads every toc file against stubs of the client and Questie, then opens the window and covers the launcher status, the dungeon line, a combat click, the Filter menu, a level change, a search and the map pins.
- Lua 5.1 allows 60 upvalues per function. Lua 5.2 and newer allow more, so the smoke test misses an overrun there. `renderList` holds about 35 because its row builders live at file level. Keep new render code there too.
- Test in game from a clone symlinked into `World of Warcraft/_forever_/Interface/AddOns/`. Turn on `/console scriptErrors 1` first.

## Release

- The toc version stays 1.0.0 until the first CurseForge release.
- A `v*` tag runs `.github/workflows/release.yml` with the BigWigs packager. The CurseForge upload also needs the `CF_API_TOKEN` secret and a toc `## X-Curse-Project-ID`. `.pkgmeta` leaves out `CLAUDE.md`, `Tests` and `Tools` and lists `questie` as a required dependency. `CHANGELOG.md` is the release changelog.
- Licence: MIT (`LICENSE`).
