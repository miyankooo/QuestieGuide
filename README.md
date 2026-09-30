# QuestieGuide

Lists every quest currently available to your character, grouped by zone, with the XP each zone is worth. Trivial grey quests are hidden automatically, unless you let Questie's own level range decide.

## Features

- **Zone list with XP** — collapsible zone headers showing the in-range quest count and the total XP for one trip through the zone (green, yellow and orange quests only), with a percent-of-level breakdown on hover
- **Next-trip banner** — names the best zone for your next trip and jumps to it on click
- **Status labels** — **[In Questlog]**, **[Available]**, **[Requires Level N]**, **[Missing Pre-Quest]** and **[Completed]**
- **Click to locate** — Available opens the world map at the start NPC with the Questie pin pulsing and a map pin on the NPC, In Questlog opens the quest log, Missing Pre-Quest jumps to the chain step you can pick up right now
- **Search** — the box at the top right matches quest names, zone names and NPC names
- **Level range sliders** — include 0–10 levels below and above you (default 5/5), or tick **Use Questie Level Ranges** to follow the range set in Questie's own **Quest Level Options** (Questie options > General). When Questie's "between two set levels" range reaches above your level, the quests you can't accept yet show dimmed as **[Requires Level N]**, the way Questie pins them with a grey "!". Like Questie, this mode also lists quests whose parent quest is in your log, and active holiday quests below the range
- **Filters** — In Questlog, Picked Up in Zone, Picked Up Outside of Zone, Missing Pre-Quest, Dungeons, Elite (Group), Repeatable
- **Quest type tags** — **[Elite (Group)]** for elite quests, plus **[Group]**, **[Dungeon]**, **[Raid]** and **[PvP]**. An elite dungeon, raid or PvP quest shows both tags, for example **[Elite (Group)] [Dungeon]**. The Elite (Group) filter covers elite, group and raid quests, and a quest with two tags shows only while both filters are on
- **Sort modes** — Total XP, Total Quest Count, Average Quest Level or Alphabetical by Zone, ascending or descending
- **Completed quests** — a category at the top grouping everything ready to turn in, by turn-in zone
- **You are here** — your current zone carries a gold tag, and the Current Zone button jumps to it
- **Focus mode** — right-click a zone header to expand it and collapse everything else
- **Item tooltips** — list every quest an item belongs to that is not in your log, marked Available, Upcoming or Completed Before
- **Level-up report** — on level up, an on-screen message and clickable chat lines name the newly available quests per zone
- **Empty-list help** — when nothing shows, a button offers the likely fix: enable the disabled filters, clear the search, or widen the level band
- **Native look** — the window is Blizzard's own panel frame with the game's dropdowns, sliders, buttons, scroll bar and tooltips
- Window position, collapsed state and every filter persist between sessions

## Installation

1. Copy the `QuestieGuide/` folder into `World of Warcraft/_classic_beta_/Interface/AddOns/`.
2. Restart the game or `/reload`.
3. Enable **Questie Guide** in the AddOns list.

## Usage

1. Open the window with the minimap button, the addon compartment next to the minimap, `/qg`, or a key binding (Key Bindings > Questie Guide).
2. Type in the search box to narrow by quest, zone or NPC name.
3. Use the dropdowns on the left to include or exclude categories and quest types and to change the sort order.
4. Click a quest to open the map at its start NPC; right-click for **Show on map** and **Link in chat**.
5. Drag the window to move it. `/qg reset` moves it back to the middle of the screen.

Shift-click a quest to link it into an open chat box.

## Requirements

- WoW Forever 1.60.x
- [Questie](https://github.com/Questie/Questie) 12 with the separate QuestieDB addon, installed and enabled. Every quest, giver, prerequisite, completion state and XP figure comes from Questie; QuestieGuide has no quest data of its own, so it only loads with Questie
- If a Questie update removes something QuestieGuide relies on, it names the missing piece in chat and keeps the window closed

## Restrictions

- Clicking a quest replaces any map pin you placed yourself.
- Only green, yellow and orange quests count toward the XP figures, the trip XP, the zone rating and the Next banner. Grey and red quests, and **[Requires Level N]** rows, still list where the level range allows them but never add XP.
- The level sliders never list red (too high) quests; **Use Questie Level Ranges** lists them when Questie does.
- Quests filed under a sort category rather than a zone (class and profession quests) are grouped under **Other**.
