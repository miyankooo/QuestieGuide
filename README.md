# WhereToQuest

A small World of Warcraft Classic Era (1.15.x) add-on that lists every quest currently available to your character. Trivial (grey) quests are hidden automatically. It relies on [Questie](https://github.com/Questie/Questie) for its quest database and eligibility logic.

## Features

- `/wtq` slash command or minimap button opens a movable, resizable dialog.
- Search box with helper text that matches against quest names, zone names, and (when **Show NPC Name and Location** or **Show NPC Coordinates** is on) NPC names.
- Scrollable list, grouped by zone, with collapsible zone and sub-category headers. Each zone header shows the visible-quest count, total reward XP, and how much of your current level that represents.
- Filters: **In Quest Log**, **Available**, **Show Chain / Picked Outside**, **Show Dungeons**, **Show Elite/Group Quests**.
- View toggles: **Show NPC Name and Location**, **Show NPC Coordinates**, **Pin Current Zone**.
- Sort modes: **Number of Quests**, **Total XP**, **Alphabetical Zone Names**.
- **Collapse / Expand** all zones and a **Refresh** button to force a re-scan, placed beneath the search box.
- Click a quest to open the World Map at its start NPC zone; the matching Questie pin pulses for a few seconds so you can spot it.
- Right-click a quest for a context menu: **Show on map**, **Link in chat**.
- Tooltips show required level, NPC, location, XP reward, objectives, repeatable / tag markers, and for chain entries the full prereq chain with each step's NPC and coordinates.
- Frame position, size, collapsed-state, and all filters/toggles persist between sessions.

## Requirements

- World of Warcraft Classic Era 1.15.x.
- Questie installed and enabled. WhereToQuest declares Questie as an optional dependency but will refuse to open without it.

## Installation

The add-on folder must live directly inside `Interface/AddOns/`, like any other WoW add-on:

```
Interface/AddOns/WhereToQuest/
├── WhereToQuest.toc
├── WhereToQuest.lua
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
2. Open the window with `/wtq` or the minimap button.
3. Type in the search box to narrow by quest, zone, or NPC name.
4. Toggle filters at the top to include or exclude categories and quest types.
5. Click a quest to open the map at its start NPC; right-click for more options.
6. Drag the bottom-right corner to resize; the frame remembers its size and position.

## How it integrates with Questie

WhereToQuest imports a small set of Questie modules through `QuestieLoader`:

- `QuestieDB` — `QuestPointers`, `IsDoable`, `GetQuest`, `QueryQuestSingle`, `GetQuestTagInfo`, `IsRepeatable`, `GetNPC`.
- `QuestieLib` — `GetTbcLevel`, `GetColoredQuestName`, `GetDifficultyColorPercent`.
- `ZoneDB` — `GetLocalizedDungeonName` for dungeon zone fallbacks and `GetUiMapIdByAreaId` for the click-to-map feature.
- `QuestiePlayer` — `currentQuestlog`, `HasRequiredRace`, `HasRequiredClass`.
- `QuestXP` — `GetQuestLogRewardXP` for per-quest and per-zone XP totals.
- `QuestieMap` — `GetFramesForQuest` to pulse a quest's icons on the world map.

A quest is shown when:

1. Its filter category is enabled.
2. Either it is in the player's quest log, or `QuestieDB.IsDoable(questId)` returns true, or it is gated only by an incomplete prerequisite chain (and matches your race/class).
3. The player meets `requiredLevel` and the effective level is no more than 5 above the player.
4. The effective level is not below the trivial (grey) threshold reported by `GetQuestGreenRange`.

Zone names come from `C_Map.GetAreaInfo` using `zoneOrSort`, with `ZoneDB:GetLocalizedDungeonName` as a fallback. Quests with non-positive `zoneOrSort` (sort categories such as class or profession buckets) are grouped under **Other**.

## Saved Variables

`WhereToQuestDB` stores the sort mode, filters, view toggles, collapsed zones/groups, minimap button angle, and frame position/size per-account.

## Notes and assumptions

- `QuestXP:GetQuestLogRewardXP` is called inside `pcall` because its signature has shifted between Questie versions; if it errors, the XP value is treated as 0.
- Trivial (grey) quests are filtered out using `GetQuestGreenRange("player")`. To see them, lower your level or pick a higher-level zone.
- The list rebuilds automatically when you change a filter, pick a new sort, or when the quest log updates / you level up. The **Refresh** button forces a re-scan.
