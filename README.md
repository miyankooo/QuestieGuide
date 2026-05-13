# WhereToQuest

A small World of Warcraft Classic Era (1.15.x) add-on that lists every quest currently available to your character within a configurable level range. It relies on [Questie](https://github.com/Questie/Questie) for its quest database and eligibility logic.

## Features

- `/wtq` slash command opens a movable dialog.
- Two numeric inputs: how many levels below and above your current level a quest may be.
- Changes persist automatically and the list refreshes after a short debounce.
- Scrollable list, grouped by zone, with collapsible zone headers.
- Toolbar with **Collapse all / Expand all** toggle and a **Sort zones by** dropdown.
- Sort modes:
  - **Alphabetical** — zone name A→Z.
  - **Number of quests** — zones with the most available quests first.
  - **Level discrepancy** — zones whose average quest level is closest to your current level first.
- Hovering a quest opens a tooltip with Questie-style details: objectives, required level, XP reward, pre-requisite quests, and the next quest in the chain.

## Requirements

- World of Warcraft Classic Era 1.15.x.
- Questie installed and enabled. WhereToQuest declares Questie as a hard dependency in its `.toc`.

## Installation

The add-on folder must live directly inside `Interface/AddOns/`, like any other WoW add-on:

```
Interface/AddOns/WhereToQuest/
├── WhereToQuest.toc
├── WhereToQuest.lua
└── README.md
```

## Usage

1. Log into a Classic Era character.
2. Type `/wtq` in chat.
3. Adjust the level range; the list refreshes automatically.
4. Pick a sort mode from the dropdown to reorder zones.
5. Use **Collapse all / Expand all** to fold or unfold every zone at once, or click a zone header to toggle just that one.
6. Hover a quest title to see its tooltip.

## How it integrates with Questie

WhereToQuest imports a small set of Questie modules through `QuestieLoader`:

- `QuestieDB` — `QuestPointers`, `IsDoable`, `GetQuest`, `QueryQuestSingle`.
- `QuestieLib` — `GetTbcLevel`, `GetColoredQuestName`, `GetDifficultyColorPercent`.
- `ZoneDB` — `GetLocalizedDungeonName` as a fallback zone name lookup.
- `QuestiePlayer` — `currentQuestlog` to exclude quests already in the log.
- `QuestXP` — `GetQuestLogRewardXP` for tooltip XP values.

A quest is shown when:

1. It is not in the player's current quest log.
2. `QuestieDB.IsDoable(questId)` returns true (race, class, profession, reputation, pre-quests, completion checks all handled by Questie).
3. Its effective level (from `QuestieLib.GetTbcLevel`) falls within the configured range around the player level.

Zone names come from `C_Map.GetAreaInfo` using `zoneOrSort`, with `ZoneDB:GetLocalizedDungeonName` as a fallback. Quests with non-positive `zoneOrSort` (sort categories such as class or profession buckets) are grouped under **Other**.

## Saved Variables

`WhereToQuestDB = { minBelow = 5, maxAbove = 3, sortMode = "name" }`

Stored per-account. `sortMode` is one of `name`, `count`, or `levelDiff`.

## Notes and assumptions

- `QuestXP:GetQuestLogRewardXP` is called inside `pcall` because its signature has shifted between Questie versions; if it errors, the XP line is simply skipped.
- Trivial quests (well below player level) appear as long as the range allows them; Questie's own "trivial quest" setting is ignored on purpose so the range value is authoritative.
- The list rebuilds when you change inputs, pick a new sort, toggle zones, or reopen the window. It does not auto-refresh on level-up; reopen the window to refresh.
