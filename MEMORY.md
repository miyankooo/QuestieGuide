---
tags: [wow, addon, questguide, questieguide, wow-forever, camelot, architecture, api-reference]
created: 2026-09-18
updated: 2026-09-21
status: memory
client_target: WoW Forever 1.60.1 (build 69913, game type camelot, Interface 16001)
client_source: WoW Classic Era 1.15.x (QuestieGuide, Interface 11509)
ui_source: Gethe/wow-ui-source @ forever, commit 70ef1b2fd78061a73f886c4a1e79dc5b5cff6d5e
---

# QuestieGuide / QuestGuide — Development Memory

The single persistent note for this directory. Read it before touching either addon instead of re-deriving anything. Consolidated on 2026-09-19 from `QuestGuide Native Quest API Architecture Analysis.md` (deleted, created 2026-09-18, revised 2026-09-19) plus the development-relevant parts of `README.md` (kept as the user-facing doc).

It covers two things:

- **QuestieGuide**, the shipped Classic Era 1.15.x addon in this folder, Questie-backed, working.
- **QuestGuide**, a planned new addon for WoW Forever 1.60.x that would source quest data from the native client API instead of Questie's bundled database. **Nothing of it is built.** Do not modify QuestieGuide to get there; QuestGuide is a new addon that reuses QuestieGuide's UI code by copy.

**Verified against:** `forever` @ `70ef1b2` (1.60.1.69913), 2026-09-21.

**Shared 1.60 client facts are not in this file.** They live in one place: `Cortex/WoW/Forever Client Facts.md` in the Obsidian vault (`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/`). Read that first — this note records only what is specific to this addon, and never restates a fact about the client. Companions there: `Two-Version Addon Architecture.md` (layout), `UI Compatibility Analysis.md` (templates and widgets). Run `../check-client-facts.sh` to see whether any of it has gone stale.

---

## Analysis

The research this addon is based on — the native quest API inventory, source-backed API
behaviour, the capability matrix, database-free feasibility, the recommended architecture and
the phased roadmap — is in `Cortex/WoW/QuestGuide Analysis.md`. It was split out of this file on
2026-09-21. Read it before designing anything; read this file before touching code.

## 1. Status and the one thing that gates everything

| Item | State |
|---|---|
| QuestieGuide version | 1.0.0, committed and clean. HEAD `d7fb2ff` "Replace route order with a repeatable-quest filter" |
| QuestieGuide repo | `github.com/miyankooo/QuestieGuide`, branch `main`. 28 commits, 2026-05-12 to 2026-08-27. No `.pkgmeta`, no CI |
| Working tree | Only `?? MEMORY.md`. The addon itself is untouched |
| QuestieGuide target | Classic Era 1.15.x only, `## Interface: 11509`, `## Dependencies: Questie` |
| QuestGuide | **Does not exist.** No folder, no code. Analysis only |
| Installed clients | Forever beta only (`_classic_beta_`, 1.60.1.69913), never logged into. `_classic_era_` is **gone** from this Mac, so QuestieGuide cannot run here at all today |
| Verified against | `Gethe/wow-ui-source` `forever` @ `70ef1b2fd78061a73f886c4a1e79dc5b5cff6d5e` ("1.60.1 (69913)"), `classic_era` @ `33e177d` ("1.15.9 (69722)"), the installed binary's string table, `Ketho/BlizzardInterfaceResources@live` |
| Last status check | **2026-09-21.** Nothing has changed since 2026-09-19. Re-checked on disk: no `QuestGuide/` folder, `git status` still only `?? MEMORY.md`, HEAD still `d7fb2ff`, client binary untouched since 2026-09-18 (149 083 936 bytes), `WTF/Account/` holds only `SavedVariables/` with three Blizzard glue files and **no account-name folder**, which is positive proof the beta has never been played past the login screen. Beta ends 2026-10-21 |

**Go / no-go.** A native-only QuestGuide is viable **if and only if** `C_QuestLine.GetAvailableQuestLines(uiMapID)` returns vanilla quest offers, including for zones the player is not standing in. That is a server-side fact no offline source can settle. **The Stage 0 probe has not been run** because no character has logged into the beta. Do not start coding before it passes. Section 10, Stage B.

**Where this note lives.** This file is the single source of truth and is **untracked** (`?? MEMORY.md`) — it is not in the GitHub repo, so it exists only on this Mac. The Obsidian note `Cortex/WoW/QuestGuide Native Quest API Architecture Analysis.md` it was consolidated from was deleted on 2026-09-19 and is **confirmed gone** from the vault; do not go looking for it.

Also note QuestieGuide and Questie 11.37.1 are both sitting in the beta AddOns folder with `## Interface: 11509` and `11508, 11509`. Their manifests declare `## Interface: 11509` and `## Interface: 11508, 11509` respectively. Neither loads on 1.60 without "Load out of date AddOns", and Questie compiles its database keyed on `WOW_PROJECT_ID` (`Database/compiler.lua:1055`), so its behaviour on camelot is undefined.

---

## 2. Environment

Client, build, branch commits and the `camelot` game-type rule are in `Cortex/WoW/Forever Client Facts.md`. Only what is specific to this addon:

- Targets **WoW Forever 1.60.x** (`16001`) and **Classic Era 1.15.x** (`11509`). `_classic_era_` has been absent from this Mac since 2026-09-18, so the 1.15.x side cannot be tested here either.
- Which quest UI loads, which Blizzard quest addons are available, and the camelot quest-UI deltas are in `Cortex/WoW/QuestGuide Analysis.md` under *Quest environment on camelot*.

---

## 3. QuestieGuide audit (the existing 1.15.x addon)

### 4.1 Inventory

| File | Lines | Role |
|---|---|---|
| `QuestieGuide.toc` | 14 | `## Interface: 11509`, `## Dependencies: Questie`, `## SavedVariables: QuestieGuideDB`, `## IconTexture: 237381` |
| `QuestieGuide.lua` | 3,526 | Entire addon: data layer, model, UI, events, tooltips, slash and binding handlers |
| `Bindings.xml` | 5 | One binding `QUESTIEGUIDE_TOGGLE` calling the global `QuestieGuide_Toggle()` |
| `Libs/` | 1,056 | LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0 — minimap launcher only |
| `README.md` | 98 | Accurate feature and integration description. **Kept**, it is the user-facing doc |

Git history shows the addon began as "WhereToQuest", was renamed twice, gained then removed a step-guide panel (2026-08-25), and replaced a route-order feature with a repeatable filter (2026-08-27).

### 4.2 Purpose and feature set

A zone-bucketed browser of every quest the character can pick up right now, rated by one-trip XP, so the player can decide where to level next. All confirmed in code:

- Movable, resizable two-pane dialog (options pane 260 px, list pane fills). Native `UI-DialogBox` backdrop and header banner, `MinimalScrollBar`, `WowStyle2DropdownTemplate` multi-select filters, `MinimalSliderWithSteppersTemplate` level sliders, `SearchBoxTemplate`.
- Zones as collapsible headers with two sub-buckets, **Picked Up in Zone** and **Picked Up Outside of Zone**, each row carrying a status badge: `[Available]`, `[In Questlog]`, `[Missing Pre-Quest]` (greyed at 50% alpha), `[Completed]` / `[Ready to Turn In]`.
- Zone header shows in-range count and one-trip XP (available now plus follow-ups projected to unlock in-zone); tooltip breaks it down including percent of current level.
- Filters: In Questlog, Picked Up in Zone, Picked Up Outside of Zone, Missing Pre-Quest, Dungeons, Elite (Group), Repeatable. Sort: total XP, count, average level, alphabetical, each ascending or descending; "Other" bucket pinned last. Rows within a zone always read in quest-level order, actionable rows first.
- Level band: `levelBelow` / `levelAbove` sliders (0–10, default 5/5) or "Use Questie Level Ranges" (yellow/green only). Red quests never count toward XP. In-log quests always list and bypass the band.
- Completed Quests section grouped by turn-in zone, sorted by turn-in count; completeness from the native quest log, turn-in location from Questie's `finishedBy`.
- Next-trip banner, current-zone `(You are here)` tag and jump button, focus mode (right-click header expands it and collapses everything else), Collapse/Expand All, empty-state button with a one-click fix.
- Click actions follow the status label: available row opens the world map at the giver and pulses the Questie pin (TomTom waypoint if installed); in-log row opens the native quest log at that quest; blocked row jumps to the first pickable chain step and blinks it. Right-click context menu (Show on map, Link in chat), shift-click chat link.
- Chain tooltip listing every prerequisite step with badge, NPC and coordinates. Item tooltip lines for quests an item belongs to, styled like Questie's own: green (Available), yellow (Upcoming), gray (Completed Before); active quests stay Questie's job. Level-up toast with clickable zone links.
- Minimap button (LibDBIcon), `/qg`, `/questieguide`, `/qg reset` (rescues an off-screen window), key binding. Frame position, size, collapsed state and all filters persist.
- Questie map icon hook: left-click a Questie pin opens the guide at that quest (or the quest log if in log).

### 4.3 Internal architecture and data flow

Single file, roughly in this order:

1. **Constants and tokens** (lines 1–130): defaults, colour tokens, spacing grid, layout tables, tag labels.
2. **Questie binding** (`loadQuestie`, line 165): waits for `Questie.started`, then imports nine modules through `QuestieLoader:ImportModule`.
3. **Static lookups with session caches**: `getZoneName` (area id via `C_Map.GetAreaInfo`, fallback `ZoneDB:GetLocalizedDungeonName`), `getQuestStartInfo` / `getQuestFinishInfo` (NPC or object spawns from `startedBy` / `finishedBy`, preferring the quest's own `zoneOrSort`), `hasReachableStarter`, `ensureFollowerIndex` (reverse prerequisite graph built once from all `QuestPointers`), `itemQuestIndex` (built 5 s after login).
4. **Eligibility and level rules**: `passesPlayerBand`, `isQuestTrivialForPlayer` (uses the Classic global `GetQuestGreenRange`), `isQuestRedForPlayer`, `meetsRequiredLevel`, `exceedsRequiredMaxLevel`, `matchesPlayerFaction`, `isBlockedByPrereqs`, `findMissingChains` (depth-limited DFS, OR vs AND semantics), `prereqsSettled`, `isLockedForProjection`, `collectZoneFollowups` (BFS over the follower index).
5. **Scan** (`scanQuestsByZone`, line 1025): iterates every quest in `QuestieDB.QuestPointers`, applies caps and `QuestieDB.IsDoable`, buckets into zones, computes per-zone stats. Synchronous. Cached in `scanCache` until invalidated.
6. **Render** (`renderList`, line 1941): sorts zones, pools row buttons, lays out headers, sub-headers, quest rows, banner, completed section and empty state by absolute y offset. Every render rebuilds every visible row.
7. **UI construction** (`buildMainFrame`, line 2465) and tooltips.
8. **Integration**: quest log via `GetQuestLogIndexByID`, `QuestLog_SetSelection`, `QuestLog_Update`, `FauxScrollFrame_SetOffset`; map via `ZoneDB:GetUiMapIdByAreaId`, `WorldMapFrame:SetMapID`, Questie pin pulse; `hooksecurefunc("SetItemRef")` for toast links; `hooksecurefunc(QuestieFrame, "CreateIconFrame")` plus a sweep of `QuestieFrame1..N` globals for pin clicks; `GameTooltip`/`ItemRefTooltip` `OnTooltipSetItem` hooks.
9. **Events** (line 3410): `ADDON_LOADED` (saved-variable normalisation), `PLAYER_LOGIN` (minimap, hooks, index build), `PLAYER_LEVEL_UP`, `QUEST_ACCEPTED`, `QUEST_REMOVED`, `QUEST_TURNED_IN` (invalidate scan, debounce 0.5 s), `UNIT_QUEST_LOG_CHANGED` (re-render only), `ZONE_CHANGED_NEW_AREA` (re-render only). `QUEST_LOG_UPDATE` is deliberately **not** registered.

Data flow in one line: **Questie DB → scan (bucket, gate, project) → scanCache → renderList → pooled rows**, with saved variables read at render time for filters, sort, collapse state and sliders.

Zone rules: a quest counts for a zone when it is set there (`zoneOrSort`) or starts at a giver there. A quest set elsewhere but picked up here lists under **Picked Up in Zone** in the giver zone and under **Picked Up Outside of Zone** in its own zone, joining both zones' XP totals. The follow-up projection uses the same rule. Quests with non-positive `zoneOrSort` (class or profession sort buckets) go under **Other**. The start-NPC location prefers a spawn in the quest's own zone; otherwise the smallest area id is the deterministic fallback.

A quest is shown when its filter category is enabled; and either it is in the quest log, or `QuestieDB.IsDoable(questId)` returns true, or it is gated only by an incomplete prerequisite chain and matches race/class. For non-log quests the player must meet `requiredLevel` and the effective level must fall in the band. For chain prerequisites the initial step itself must pass `IsDoable`; for `preQuestGroup` (AND) gating every incomplete prereq is surfaced as its own row.

### 4.4 Questie data dependencies

Nine modules imported via `QuestieLoader:ImportModule`: `QuestieDB`, `QuestieLib`, `ZoneDB`, `QuestiePlayer`, `QuestXP`, `QuestieMap`, `QuestieLink`, `QuestieCorrections`, `QuestieTooltips`.

| Questie module / field | Used for | Native 1.60 equivalent |
|---|---|---|
| `QuestieDB.QuestPointers` | Enumerate all quests | None; only quests the server currently offers or the player holds |
| `QuestieDB.IsDoable` | Eligibility (race, class, faction, rep, prereq, exclusivity, breadcrumb) | Server-side, implicit in the offer feed |
| `QueryQuestSingle`: `name`, `questLevel`, `requiredLevel`, `requiredMaxLevel` | Title, level, gates | `C_QuestLog.GetTitleForQuestID`, `GetQuestDifficultyLevel`, `QuestLineInfo.questName`; required level not exposed |
| `zoneOrSort` | "Set in zone" bucket | The map the offer was returned on, `startMapID`; sort categories not exposed |
| `startedBy` (NPC, object, item ids), `finishedBy` | Giver and turn-in name, spawn, area | Position only via `QuestLineInfo.x, y` and `C_QuestLog.GetNextWaypoint`; **no names, no ids** |
| `preQuestSingle`, `preQuestGroup`, `parentQuest`, `exclusiveTo`, `nextQuestInChain`, `breadcrumbForQuestId` | Chains, blocked rows, follow-up projection | **None** |
| `requiredRaces`, `requiredClasses` | Faction/class match | Server-side, implicit |
| `objectives`, `sourceItemId`, `requiredSourceItems`, item `startQuest` | Item tooltip quest lines | **None** |
| `GetQuestTagInfo`, `IsRepeatable` | Elite, Dungeon, Raid, PvP, Repeatable | `C_QuestLog.GetQuestTagInfo`, `IsRepeatableQuest`, `IsEliteQuest`, `GetQuestType` |
| `QuestXP:GetQuestLogRewardXP` | XP totals | `GetQuestLogRewardXP(questID)` global (6.4) |
| `QuestieLib.GetEffectiveQuestLevel`, `GetColoredQuestName`, `GetDifficultyColorPercent` | Level scaling and colour | `C_PlayerInfo.GetContentDifficultyQuestForPlayer` and `GetDifficultyColor` |
| `QuestiePlayer.currentQuestlog`, `GetCurrentZoneId` | Log set, current zone | `C_QuestLog.GetInfo` loop, `C_Map.GetBestMapForUnit("player")` |
| `ZoneDB:GetUiMapIdByAreaId` | Area id → uiMapID | Not needed; work in uiMapIDs from the start |
| `QuestieMap:GetFramesForQuest`, `QuestieFrame` globals | Pin pulse and click hook | Own `MapCanvasDataProvider`, `EventRegistry "MapCanvas.PingQuestID"` for log quests |
| `QuestieLink:GetQuestLinkString` | Chat link | `GetQuestLink(questID)` |
| `QuestieCorrections.hiddenQuests`, `QuestieDB.autoBlacklist`, `Questie.db.char.hidden` | Blacklists | Not needed |
| `QuestieTooltips.lookupByKey`, `Questie.db.profile.*` | Item tooltip dedupe | Not needed |

### 4.5 Native API QuestieGuide already uses, checked against the 1.60 binary

| Symbol | 1.60.1.69913 binary | Consequence |
|---|---|---|
| `GetQuestGreenRange` | **Absent** | Trivial detection must move to `C_QuestLog.IsQuestTrivial` / `GetTrivialRange` / `C_PlayerInfo.GetContentDifficultyQuestForPlayer` |
| `GetQuestLogIndexByID` | **Absent** | Use `C_QuestLog.GetLogIndexForQuestID` |
| `QuestLogFrame`, `QuestLog_SetSelection`, `QuestLog_Update`, `QuestLogListScrollFrame` | Not loaded (Vanilla-only Lua) | Use `QuestMapFrame_OpenToQuestDetails(questID)` |
| `IsQuestFlaggedCompleted` (global) | Present | Prefer `C_QuestLog.IsQuestFlaggedCompleted` |
| `C_Map.GetAreaInfo`, `GetMapArtLayers`, `GetMapInfo` | Present, documented | Reusable |
| `MenuUtil.CreateContextMenu`, `WowStyle2DropdownTemplate`, `MinimalSliderWithSteppersTemplate`, `MinimalScrollBar`, `SearchBoxTemplate`, `BackdropTemplate` | Mainline templates | Reusable as-is — these were back-ported to 1.15, which is why the UI code is already retail-shaped |
| `hooksecurefunc("SetItemRef")` | Present | Reusable |
| `UnitLevel`, `UnitXPMax`, `UnitFactionGroup` | Present | Reusable |

### 4.6 Duplicated data, legacy layers, brittle assumptions, risks

**Duplicated or derived data.** Zone names are derived twice (from `zoneOrSort` and from giver spawn area) and stored under a string key, so two areas with equal localized names would merge — the new design must key by `uiMapID`. `startInfoCache`, `finishInfoCache` and `reachableStarterCache` never invalidate and assume Questie's DB is immutable for the session. Quest tables are copied into every zone bucket they touch, then `unlocksHere` is marked per copy.

**Legacy compatibility layers.** `queryQuestLevels` resolves `GetEffectiveQuestLevel` or the renamed `GetTbcLevel` and falls back to raw fields. `getQuestXp` wraps `QuestXP:GetQuestLogRewardXP` in `pcall` because its signature changed between Questie versions. `highlightQuestOnMap` probes `SetScale`/`SetScaleFrom`/`SetChange`/`SetFromAlpha` for both old and new animation APIs. `ADDON_LOADED` deletes a long list of retired saved-variable keys (`minBelow`, `maxAbove`, `showNpcName`, `showCoords`, `pinCurrentZone`, `routeSort`, `showHidden`, `hiddenQuests`, `steps*`) instead of running versioned migrations. `QuestieGuideDB.minimap.angle` migrates to LibDBIcon's `minimapPos`.

**Brittle assumptions.** Depends on undocumented Questie internals: `Questie.started`, `QuestieLoader`, `QuestieFrame` global naming, `QuestieCorrections.hiddenQuests`, `QuestieTooltips.lookupByKey["i_"..id]`, `Questie.db.profile.enableTooltips`, the `startedBy` 3-tuple and `finishedBy` 2-tuple layouts, `objectives[3]` and `objectives[6]` positional shapes. Classic-only globals (`GetQuestGreenRange`, `GetQuestLogIndexByID`, `QuestLogFrame`) hard-fail on 1.60. `CLASSIC_MAX_LEVEL = 60` rejects any quest Questie ships above 60 — harmless on vanilla data but a silent filter. `renderList` sits at Lua 5.1's 60-upvalue limit (comment at line 90), which is why constants were grouped into tables; **any further growth breaks compilation.**

**Performance risks.** `scanQuestsByZone` walks every quest in Questie's compiled DB synchronously on each invalidation (accept, remove, turn-in, level-up), mitigated only by the 0.5 s debounce. `findMissingChains` runs per blocked quest per scan with depth 12 and branch cloning of `visited`. `collectZoneFollowups` runs a BFS per zone per scan. `announceNewQuests` walks the full DB one second after every level-up. `buildItemQuestIndex` walks the full DB once at login (deferred 5 s). `renderList` re-lays out every row on every filter click, collapse toggle, search keystroke and scroll-frame resize; the row pool never shrinks.

**Maintenance bottlenecks.** One 3,526-line file mixing data, model, UI, integration and events. Forward declarations (`renderList`, `expandAndScrollToZone`, `getQuestTagLabel`, `getQuestXp`, `formatNumber`) exist only to work around single-file ordering. No tests, no debug toggle, no error surface beyond `print`. Hard-coded English strings.

**Saved variables.** `QuestieGuideDB` (account-wide) stores sort mode, filters, view toggles, level-range sliders, collapsed zones and groups, minimap button position, frame position and size.

**Design token convention.** All sizing, spacing and font values sit on a 4px grid, stated as multiples of the grid unit (`SPACING.XS`) or derived from tokens that are. Colours are tokenized one entry per role (`COLOR` table); raw `|cff` literals outside those tables are limited to data-driven composition from `QUEST_TAG_COLORS` and difficulty colours. Two documented exemptions, both marked `NATIVE` in code: metrics mirroring external art (WowStyle2 dropdown height, dialog-header banner, QuestLogFrame toggle inset, SearchBox texture offset, Questie's sizer diagonals) and derived centering insets (`ROW_PAD`, half the difference between row height and font size).

### 4.7 Reuse verdict for QuestGuide

| Component | Verdict | Reason |
|---|---|---|
| Frame shell (`buildMainFrame`, `buildSection`, `buildGroup`, `buildCheckbox`, `buildTitleHeader`, `applyPanelBackdrop`, resize grip, `UISpecialFrames`) | **Reuse** (copy, split into a UI module) | Already Mainline templates |
| Filter and sort dropdown builders, slider builder | **Reuse** | Template code is version-neutral |
| Row pool (`rowPool`), `styleHeaderRow`, `acquireRow`, `placeRow`, `sizeRow`, `hideUnusedRows`, `flashRow`, scroll and `MinimalScrollBar` wiring | **Reuse** | Rendering only; decouple from scan shape |
| Level-band rules (`isLevelInBand`, `clampRange`, `getLevelRange`) | **Reuse**, swap difficulty tiers to `RelativeContentDifficulty` | Pure functions |
| `sortZones`, `formatNumber`, collapse-state model, empty-state logic, `DEFAULTS` pattern, the `COLOR` / `SPACING` / `LAYOUT` / `LIST` token tables | **Reuse** | Pure |
| Minimap launcher, slash commands, key binding, toast link handler | **Reuse** with renamed globals | |
| Zone tooltip, quest tooltip layout, `addTooltipField` | **Adapt** | Field sources change |
| `scanQuestsByZone`, start/finish info, `hasReachableStarter`, `matchesPlayerFaction` | **Redesign** | Becomes an async provider |
| Prerequisite chain code, follow-up projection, blocked rows | **Redesign behind an optional provider**; absent in native-only mode | No native data |
| Item tooltip index and hooks | **Discard** in native mode; optional static provider later | No native item→quest data |
| Questie pin hooks, `highlightQuestOnMap`, `openMapForQuest` via `ZoneDB` | **Discard**; replace with own data provider and `C_Map.SetUserWaypoint` | |
| `openQuestInLog` (Vanilla quest log) | **Discard**; replace with `QuestMapFrame_OpenToQuestDetails` | Frame does not exist on 1.60 |
| Saved-variable key cleanup | **Discard**; replace by versioned migration | |
| Questie `Colorize`, `QuestieLink` formats | **Discard** | |

---

## 4. Risks and unresolved questions

Every row is a `[TEST]` item from sections 5 to 7. "Probe" names the Stage 0 test that closes it.

| # | Unknown | Impact | Probe |
|---|---|---|---|
| 1 | Does the server populate `C_QuestLine.GetAvailableQuestLines` for vanilla quests, and for maps the player is not on? | **Fatal if no** | B1, B3 |
| 2 | Does `GetQuestLogRewardXP(questID)` return XP for offers not in the log after `RequestPreloadRewardData`? | Zone XP totals | B7 |
| 3 | Semantics of `QuestLineInfo.isHidden` — trivial versus intentionally hidden | Trivial filter accuracy | B5, B6 |
| 4 | Server throttling or rate limits on `RequestQuestLinesForMap` fan-out | Scan latency, possible disconnect | F2, F4 |
| 5 | `QUEST_DATA_LOAD_RESULT` failures for some vanilla quests | Missing titles | C8 |
| 6 | Does `GetQuestObjectives` return rows for an unaccepted, ID-loaded quest? | Objective preview before acceptance | C3 |
| 7 | Does `Enum.QuestObjectiveType` exist, and what are its values? The docs name the type but never define it | Objective categorisation; do not hard-code strings until answered | C5 |
| 8 | Are the classic objective `type` strings (`"monster"`, `"item"`, …) still used? Only `"progressbar"` is confirmed | Same | C4 |
| 9 | World map id and zone enumeration on camelot | Scan coverage | F1 |
| 10 | Atlas availability on camelot — Ketho has no `forever` branch | Pin art | D8 |
| 11 | Dungeon and instance quests: are dungeon maps in the feed, and does `startMapID` point to the dungeon or the entrance zone? | Dungeon filter | B10 |
| 12 | Account-completed filtering on a fresh realm (`isAccountCompleted`) | Missing offers for alts | F5 |
| 13 | Addon restriction state on camelot (`Blizzard_RestrictedAddOnEnvironment`, secret values) | `UnitName("npc")` capture, every native quest API call (`Cortex/WoW/QuestGuide Analysis.md`, *Native quest API inventory*) | A4, A5 |
| 14 | Behaviour of `C_Map.OpenWorldMap` (`HasRestrictions`) versus `ShowUIPanel(WorldMapFrame)` | Show on map | E7 |
| 15 | Are `Enum.GameRule.QuestLogPanelDisabled` / `WorldMapDisabled` active on camelot? | Quest log open path | A6 |
| 16 | What does the always-on `MinimapTrackingFilter.QuestPOIs` actually draw, and can an addon coexist with it? | Minimap feature scope | D5, D6, D7 |
| 17 | Does the server ship quest waypoint data for vanilla quests? | Native routing | C9 |
| 18 | Do quest hubs exist in vanilla zones? | Hub suppression logic in map pins | B8 |
| 19 | Can a third-party `MapCanvasDataProviderMixin` provider register on `WorldMapFrame` without taint? | Own map pins | Stage 1 |
| 20 | Licensing of any static dataset derived from Questie | Stage 6 | See 12.1 — **Questie has no LICENSE file at all** |

---

## 5. Final recommendation and next steps

**Build QuestGuide as a new 1.60-only addon with a hybrid, native-first architecture.** Native-only for the MVP; a runtime observation layer from day one; an optional static data pack only if prerequisite chains are missed in play — or as a first-class deliverable if objective mobs are required (*Dual-version feasibility* in `Cortex/WoW/QuestGuide Analysis.md`).

**Tradeoffs.** Native-only gives authoritative "available now" data with zero maintenance of quest tables, works the day new content lands, and reuses Blizzard's own pins, waypoints and quest log. It loses prerequisite chains, NPC names and item tooltips, and it is asynchronous. Database-backed (Questie-style) restores everything but re-creates the exact dependency the user wants to escape, at 71 MB of data and months of catch-up risk on WoW Forever. Hybrid costs one abstraction (the provider interface) and pays it back the first time a data pack or second source appears.

**Minimum viable product.** Zone-bucketed list of currently offered quests with level, difficulty colour, tags, XP, objectives tooltip, in-log and ready states, completed section, level band and filters, sort by one-trip XP (now only), next-trip banner, current-zone jump, search by quest and zone, show-on-map with native supertrack or waypoint, open in quest log, chat link, level-up toast, minimap button, slash and binding. **No blocked rows, no NPC names beyond observation, no item tooltips.**

### Ordered checklist

Nothing below step 3 should start before step 2 passes.

- [ ] **1. Log a low-level character into the 1.60 beta.** No `WTF/Account/<name>` exists yet, so nothing has been observed in the client. Note `select(4, GetBuildInfo())` to confirm Interface `16001`.
- [ ] **2. Run the Stage 0 probe** (phased roadmap in `Cortex/WoW/QuestGuide Analysis.md`) in Elwynn Forest or Durotar, then for a second zone selected on the world map. Record: offer count, one quest's title, difficulty, `HaveQuestRewardData`, `GetQuestLogRewardXP`, the zone-map count from `C_Map.GetMapChildrenInfo`, and `UnitName("npc")` while a gossip window is open. Paste the output into a new note `QuestGuide Probe Results`.
- [ ] **3. Decide go / no-go** against the Stage B decision table.
- [ ] **4. Create the addon skeleton**: `Interface/AddOns/QuestGuide/` with the manifest from 9.15 and `Core/Init`, `Core/Compat`, `Core/Events`, `Data/QuestCache`, `Data/MapScanner`, `Debug` from 9.16. **Do not touch QuestieGuide.**
- [ ] **5. Stage 1 acceptance**: `/qg scan` lists per-zone offer counts, full scan under 5 s, no Lua errors, `failed` count reported.
- [ ] **6. Stage 2 model and native provider**, then **Stage 3 UI port** (copy QuestieGuide's shell, rows, options, tooltips per 4.7 and 9.17).
- [ ] **7. Stage 4 map and waypoints**, **Stage 5 observation layer**, then decide on the optional `QuestGuide_Data` pack (Stage 6) — first-class if objective mobs are required, and only after the licence question in 12.1 is settled.
- [ ] **8. Re-verify against `Gethe/wow-ui-source@forever`** on every new 1.60.x build before release; update the commit hashes in the Sources section of `Cortex/WoW/QuestGuide Analysis.md`, and re-run `../check-client-facts.sh`.

**Most important unknowns, in order:** offer feed population for zones the player is not standing in; reward XP for non-log offers; interface number and zone enumeration; `isHidden` semantics and dungeon map behaviour.

### QuestieGuide itself

No work is planned. It is committed, clean and functional on 1.15.x. It cannot be run on this machine because `_classic_era_` is not installed. If it is ever revisited: the 60-upvalue ceiling in `renderList` (4.6) is the first thing that will bite, and the single-file layout is the reason — the sibling addons' `Core/` + `UI/` split is the convention to follow — see `Cortex/WoW/Two-Version Addon Architecture.md`.

---

## 6. Probe results

Empty as of 2026-09-21 — the probe has still not been run. One table per Stage 0 stage, with ID, exact command, raw output, pass or fail, and any Lua error verbatim. Every `[TEST]` tag becomes `[GAME]` with a date as it is answered.
