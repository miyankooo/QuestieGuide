# Questie Guide

A small World of Warcraft Classic Era (1.15.x) add-on that lists every quest currently available to your character. Trivial (grey) quests are hidden automatically. It relies on [Questie](https://github.com/Questie/Questie) for its quest database and eligibility logic.

## Features

- Minimap button opens a movable, resizable dialog.
- Search box with helper text that matches against quest names, zone names, and NPC names.
- Scrollable list, grouped by zone, with collapsible zone and sub-category headers. Each zone splits into **Picked Up in Zone** and **Picked Up Outside of Zone**. Every quest carries a color-coded status label: yellow **[In Questlog]**, green **[Available]** or red **[Missing Pre-Quest]**. Blocked quests render greyed at 50% opacity. Each zone header shows the in-range quest count and the total XP for one trip through the zone; hovering the header shows the breakdown including percent of your current level.
- **Quest Level Range** sliders configure how many levels below and above the player to include (each 0–10, default 5/5), with a **Use Questie Level Ranges** checkbox that switches to yellow/green difficulty gating instead. Red quests never count toward the XP figures. Quests already in your log are always shown regardless of the range.
- Filters: **In Questlog** (toggles the yellow in-log rows), **Picked Up in Zone**, **Picked Up Outside of Zone**, **Missing Pre-Quest** (toggles the greyed blocked rows), **Dungeons**, **Elite (Group)**.
- Sort modes: **Total XP**, **Total Quest Count**, **Average Quest Level**, **Alphabetical by Zone**, each ascending or descending. The sort setting governs every zone.
- **Visibility Filters** section with a **Show Completed Quests** checkbox (default on). When checked, a **Completed Quests** category sits at the top of the list, grouping quests that are ready to turn in by their turn-in zone, sorted by turn-in count. Rows carry a green **[Ready to Turn In]** label; clicking opens the World Map at the turn-in target with the matching Questie pin pulsing. Completeness comes from the native quest log; the turn-in location comes from Questie's `finishedBy` data.
- **Collapse / Expand** all zones with one button beneath the search box.
- Clicking follows the status label: **[Available]** opens the World Map at the start NPC with the matching Questie pin pulsing, **[In Questlog]** opens the native quest log at that quest, and **[Missing Pre-Quest]** jumps the list to the chain step you can pick up right now and blinks it.
- Right-click a quest for a context menu: **Show on map**, **Link in chat**. Shift-click links the quest directly into an open chat box.
- Tooltips show required level, NPC, location, XP reward, objectives, repeatable / tag markers, and for chain entries the full prereq chain with each step's NPC and coordinates.
- **Next-trip banner** at the top of the list names the best zone for your next trip with its one-trip XP and percent of your current level. Click it to jump to that zone.
- **Route Order Within Zones** (Sorting section, default on) re-sorts each zone's pickable rows into a nearest-neighbor pickup route, numbered `1. 2. 3.`, seeded from your position when you are in that zone. Gaps in the numbering mean stops hidden by search or filters.
- The zone you are standing in carries a gold **(You are here)** header tag; the **Current Zone** button next to Collapse All jumps to it. Both update when you cross a zone border.
- **Focus mode**: right-click any zone header to expand it and collapse everything else.
- **Item tooltips** list every quest an item belongs to that is not in your quest log, styled like Questie's own lines: green **(Available)**, yellow **(Upcoming)** for level- or prereq-gated quests, gray **(Completed Before)**. Active quests stay Questie's job.
- **Level-up toast**: on level up, an on-screen message and a chat line report newly available quests per zone. Zone names in chat are clickable and open the panel at that zone.
- When the list is empty, a button offers the likely fix: enable the disabled filters, clear the search, or widen the level band.
- With TomTom installed, clicking a quest also sets a TomTom waypoint at the giver. Classic Era has no native waypoint API, so without TomTom the pulsing Questie map pin is the locate cue.
- Toggle the panel with `/qg`, `/questieguide`, a key binding (Key Bindings > Questie Guide), or the minimap button. `/qg reset` rescues a window dragged off-screen.
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
├── Bindings.xml
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

- `QuestieDB` — `QuestPointers`, `IsDoable`, `IsComplete`, `GetQuest`, `QueryQuestSingle`, `QueryObjectSingle`, `GetQuestTagInfo`, `IsRepeatable`, `GetNPC`, `IsPreQuestSingleFulfilled`, `IsPreQuestGroupFulfilled`.
- `QuestieLib` — `GetEffectiveQuestLevel` (formerly `GetTbcLevel`, with a raw-DB fallback), `GetColoredQuestName`, `GetDifficultyColorPercent`.
- `ZoneDB` — `GetLocalizedDungeonName` for dungeon zone fallbacks and `GetUiMapIdByAreaId` for the click-to-map feature.
- `QuestiePlayer` — `currentQuestlog`, `HasRequiredRace`, `HasRequiredClass`.
- `QuestXP` — `GetQuestLogRewardXP` for per-quest and per-zone XP totals.
- `QuestieMap` — `GetFramesForQuest` to pulse a quest's icons on the world map.
- `QuestieLink` — `GetQuestLinkString` to build the Questie-flavored chat link for **Link in chat**.
- `QuestieCorrections` — `hiddenQuests` to keep blacklisted quests out of the blocked-quest rows and item tooltips.
- `QuestieTooltips` — `lookupByKey` to skip item tooltip lines Questie already renders for quest-starting items.

A quest is shown when:

1. Its filter category is enabled.
2. Either it is in the player's quest log, or `QuestieDB.IsDoable(questId)` returns true, or it is gated only by an incomplete prerequisite chain (and matches your race/class).
3. For non-log quests, the player meets `requiredLevel` and the effective level falls within the configured **Quest Level Range** band. In-log quests bypass the band.
4. For **Chain Prerequisites**, the initial step itself must pass `QuestieDB.IsDoable` (race, class, faction, reputation, exclusivity, breadcrumb). For `preQuestGroup` (AND) gating, every incomplete prereq is surfaced as its own row so the player sees all initials they have to pick up.

Zone names come from `C_Map.GetAreaInfo` using `zoneOrSort`, with `ZoneDB:GetLocalizedDungeonName` as a fallback. Quests with non-positive `zoneOrSort` (sort categories such as class or profession buckets) are grouped under **Other**.

A quest counts for a zone when it is set in the zone (`zoneOrSort`) or starts at a giver in the zone. A quest set elsewhere but picked up here lists under **Picked Up in Zone** in the giver zone and under **Picked Up Outside of Zone** in its own zone, and it joins both zones' XP totals. The follow-up projection uses the same rule, so chain steps that continue from a giver in the zone count toward the one-trip total even when they are filed under another zone or a sort category. In-log and prereq-blocked quests follow the same bucketing; blocked quests render greyed until their chain is cleared. The start-NPC location displayed on each row prefers a spawn that lives in the quest's own zone; if the NPC doesn't spawn there, the smallest area id is used as a deterministic fallback.

## Saved Variables

`QuestieGuideDB` stores the sort mode, route-order toggle, filters, view toggles, level-range sliders, collapsed zones/groups, minimap button position, and frame position/size per-account.

## Notes and assumptions

- `QuestXP:GetQuestLogRewardXP` is called inside `pcall` because its signature has shifted between Questie versions; if it errors, the XP value is treated as 0.
- The **Quest Level Range** sliders gate which non-log quests are surfaced. Lower the **below** slider to hide near-trivial quests, or raise the **above** slider to see slightly higher-level ones that are still flagged as doable.
- The list rebuilds automatically when you change a filter, pick a new sort, cross a zone border, or when the quest log updates / you level up.
