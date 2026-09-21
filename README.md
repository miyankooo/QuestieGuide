# QuestieGuide

Lists every quest currently available to your character, grouped by zone, with the XP each zone is worth. Trivial grey quests are hidden automatically.

## Features

- **Zone list with XP** — collapsible zone headers showing the in-range quest count and the total XP for one trip through the zone, with a percent-of-level breakdown on hover
- **Next-trip banner** — names the best zone for your next trip and jumps to it on click
- **Status labels** — yellow **[In Questlog]**, green **[Available]**, red **[Missing Pre-Quest]**, green **[Ready to Turn In]**
- **Click to locate** — Available opens the world map at the start NPC with the Questie pin pulsing, In Questlog opens the quest log, Missing Pre-Quest jumps to the chain step you can pick up right now
- **Search** — matches quest names, zone names and NPC names
- **Level range sliders** — include 0–10 levels below and above you (default 5/5), or switch to Questie's own yellow/green difficulty gating
- **Filters** — In Questlog, Picked Up in Zone, Picked Up Outside of Zone, Missing Pre-Quest, Dungeons, Elite (Group), Repeatable
- **Sort modes** — Total XP, Total Quest Count, Average Quest Level or Alphabetical by Zone, ascending or descending
- **Completed quests** — a category at the top grouping everything ready to turn in, by turn-in zone
- **You are here** — your current zone carries a gold tag, and the Current Zone button jumps to it
- **Focus mode** — right-click a zone header to expand it and collapse everything else
- **Item tooltips** — list every quest an item belongs to that is not in your log, marked Available, Upcoming or Completed Before
- **Level-up report** — on level up, an on-screen message and clickable chat lines name the newly available quests per zone
- **Empty-list help** — when nothing shows, a button offers the likely fix: enable the disabled filters, clear the search, or widen the level band
- Window position, size, collapsed state and every filter persist between sessions

## Installation

1. Copy the `QuestieGuide/` folder into `World of Warcraft/_classic_era_/Interface/AddOns/`.
2. Restart the game or `/reload`.
3. Enable **Questie Guide** in the AddOns list.

## Usage

1. Open the window with the minimap button, `/qg`, or a key binding (Key Bindings > Questie Guide).
2. Type in the search box to narrow by quest, zone or NPC name.
3. Toggle the filters at the top to include or exclude categories and quest types.
4. Click a quest to open the map at its start NPC; right-click for **Show on map** and **Link in chat**.
5. Drag the bottom-right corner to resize. `/qg reset` rescues a window dragged off-screen.

Shift-click a quest to link it into an open chat box.

## Requirements

- WoW Classic Era 1.15.x
- [Questie](https://github.com/Questie/Questie), installed and enabled — QuestieGuide supplies its own UI but takes the quest database and eligibility logic from Questie, and refuses to open without it
- [TomTom](https://www.curseforge.com/wow/addons/tomtom) is optional; with it installed, clicking a quest also sets a waypoint

## Restrictions

- Classic Era has no native waypoint API, so without TomTom the pulsing Questie map pin is the only locate cue.
- Red (too high) quests are shown but never counted toward the XP figures.
- Quests filed under a sort category rather than a zone (class and profession quests) are grouped under **Other**.
