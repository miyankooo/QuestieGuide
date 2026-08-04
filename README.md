# Questie Guide

A small World of Warcraft Classic Era (1.15.x) add-on that lists every quest currently available to your character. Trivial (grey) quests are hidden automatically. It relies on [Questie](https://github.com/Questie/Questie) for its quest database and eligibility logic.

## Features

- Minimap button opens a movable, resizable dialog.
- Search box with helper text that matches against quest names, zone names, and NPC names.
- Scrollable list, grouped by zone, with collapsible zone and sub-category headers. Each zone header shows the in-range quest count, the XP available right now, and the one-trip chain total in brackets; hovering the header shows the full breakdown including percent of your current level.
- **Quest Level Range** sliders configure how many levels below and above the player to include (each 0–10, default 5/5), with a **Use Questie Level Ranges** checkbox that switches to yellow/green difficulty gating instead. Red quests never count toward the XP figures. Quests already in your log are always shown regardless of the range.
- Filters: **In Quest Log**, **Available in Zone**, **Available Elsewhere**, **Missing Pre-Quest**, **Dungeons**, **Elite (Group)**.
- Sort modes: **Currently Available XP**, **Total Chain XP**, **Total Quest Count**, **Average Quest Level**, **Alphabetical by Zone**, each ascending or descending. The sort setting governs every zone.
- **Collapse / Expand** all zones with one button beneath the search box.
- Click a quest to open the World Map at its start NPC zone; the matching Questie pin pulses for a few seconds so you can spot it.
- Right-click a quest for a context menu: **Show on map**, **Link in chat**.
- Tooltips show required level, NPC, location, XP reward, objectives, repeatable / tag markers, and for chain entries the full prereq chain with each step's NPC and coordinates.
- Frame position, size, collapsed-state, and all filters/toggles persist between sessions.

## Requirements

- World of Warcraft Classic Era 1.15.x.
- Questie installed and enabled. Questie Guide declares Questie as an optional dependency but will refuse to open without it.

## Installation

The add-on folder must live directly inside `Interface/AddOns/`, like any other WoW add-on:

```
Interface/AddOns/QuestieGuide/
├── QuestieGuide.toc
├── QuestieGuide.lua
├── Libs/
│   ├── LibStub/
│   ├── CallbackHandler-1.0/
│   ├── LibDataBroker-1.1/
│   └── LibDBIcon-1.0/
└── README.md
```

The embedded libraries (LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0) expose the minimap launcher to any addon-manager UI (e.g. CleanUI, Titan Panel) for consistent edge placement.

## Usage

1. Log into a Classic Era character.
2. Open the window with the minimap button.
3. Type in the search box to narrow by quest, zone, or NPC name.
4. Toggle filters at the top to include or exclude categories and quest types.
5. Click a quest to open the map at its start NPC; right-click for more options.
6. Drag the bottom-right corner to resize; the frame remembers its size and position.

## How it integrates with Questie

Questie Guide imports a small set of Questie modules through `QuestieLoader`:

- `QuestieDB` — `QuestPointers`, `IsDoable`, `GetQuest`, `QueryQuestSingle`, `GetQuestTagInfo`, `IsRepeatable`, `GetNPC`, `IsPreQuestSingleFulfilled`, `IsPreQuestGroupFulfilled`.
- `QuestieLib` — `GetTbcLevel`, `GetColoredQuestName`, `GetDifficultyColorPercent`.
- `ZoneDB` — `GetLocalizedDungeonName` for dungeon zone fallbacks and `GetUiMapIdByAreaId` for the click-to-map feature.
- `QuestiePlayer` — `currentQuestlog`, `HasRequiredRace`, `HasRequiredClass`.
- `QuestXP` — `GetQuestLogRewardXP` for per-quest and per-zone XP totals.
- `QuestieMap` — `GetFramesForQuest` to pulse a quest's icons on the world map.
- `QuestieLink` — `GetQuestLinkString` to build the Questie-flavored chat link for **Link in chat**.

A quest is shown when:

1. Its filter category is enabled.
2. Either it is in the player's quest log, or `QuestieDB.IsDoable(questId)` returns true, or it is gated only by an incomplete prerequisite chain (and matches your race/class).
3. For non-log quests, the player meets `requiredLevel` and the effective level falls within the configured **Quest Level Range** band. In-log quests bypass the band.
4. For **Chain Prerequisites**, the initial step itself must pass `QuestieDB.IsDoable` (race, class, faction, reputation, exclusivity, breadcrumb). For `preQuestGroup` (AND) gating, every incomplete prereq is surfaced as its own row so the player sees all initials they have to pick up.

Zone names come from `C_Map.GetAreaInfo` using `zoneOrSort`, with `ZoneDB:GetLocalizedDungeonName` as a fallback. Quests with non-positive `zoneOrSort` (sort categories such as class or profession buckets) are grouped under **Other**. The start-NPC location displayed on each row prefers a spawn that lives in the quest's own zone; if the NPC doesn't spawn there, the smallest area id is used as a deterministic fallback.

## Saved Variables

`QuestieGuideDB` stores the sort mode, filters, view toggles, level-range sliders, collapsed zones/groups, minimap button position, and frame position/size per-account.

## Notes and assumptions

- `QuestXP:GetQuestLogRewardXP` is called inside `pcall` because its signature has shifted between Questie versions; if it errors, the XP value is treated as 0.
- The **Quest Level Range** sliders gate which non-log quests are surfaced. Lower the **below** slider to hide near-trivial quests, or raise the **above** slider to see slightly higher-level ones that are still flagged as doable.
- The list rebuilds automatically when you change a filter, pick a new sort, or when the quest log updates / you level up. The **Refresh** button forces a re-scan.
