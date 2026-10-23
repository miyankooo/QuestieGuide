# Questie Guide

An unofficial Questie companion that lists every quest you can pick up now, grouped by zone and rated by the XP of one trip through each zone.

## Features

- A Next banner names the best zone for your next trip and jumps to it.
- Zone headers show the quest count and trip XP, with a breakdown on hover that includes follow-up quests unlocking in the same zone.
- Rows read like Forever's quest log, for example `[24+] Quest Name (Dungeon)`, with a status only when it matters: In Questlog, Requires Level N or Missing Pre-Quest.
- Click a quest to open the world map at its giver with a waypoint, or the quest log for a quest you already have. A Missing Pre-Quest row jumps to the chain step you can do now.
- One Filter menu holds availability, quest types, completed quests, the level range and the sort order.
- Completed quests are grouped by turn-in zone at the top of the list.
- Item tooltips name the quests an item belongs to that are not in your log yet.
- Chat lines with clickable zone links on level up and when you enter a dungeon that still has quests to pick up.

## Installation

1. Install it with the CurseForge app under WoW Forever, or copy the `QuestieGuide` folder into `World of Warcraft/_classic_beta_/Interface/AddOns/`.
2. Restart the game or type `/reload`.
3. Enable Questie Guide in the AddOns list.

## Usage

1. Open the window with the minimap button, the addon menu next to the minimap, `/qg` or a key binding (Key Bindings, Questie Guide).
2. Read the Next banner, or open the zone you are in with Current Zone.
3. Type in the search box to narrow the list by quest, zone or NPC name.
4. Click a quest to open the map at its giver. Right-click it for Show on Map and Link in Chat. Shift-click links it into an open chat box. Right-click a zone header to expand it and collapse every other zone.
5. Click a Questie "!" on the map to open the guide at that quest.

## Commands

| Command | Does |
| --- | --- |
| `/qg` | Opens or closes the window |
| `/qg minimap` | Hides or shows the minimap button. The addon menu entry stays |
| `/qg reset` | Moves the window back to the middle of the screen |

`/questieguide` works as well.

## Settings

The Filter button next to the search box holds every option. Its reset button appears while any filter differs from the defaults.

- Availability: In Questlog, Starts Here, Starts Elsewhere and Missing Pre-Quest.
- Quest Types: Dungeons, Elite and Repeatable.
- Show Completed: the completed quests section.
- Level Range: Questie Level Ranges follows the range set in Questie's options (General, Quest Level Options). Custom Range lists quests from 0 to 10 levels below and above you, 5 and 5 by default.
- Sort By: Total XP, Total Quest Count, Average Quest Level or Alphabetical by Zone, ascending or descending.

The window position, collapsed zones and every filter persist between sessions.

## Requirements

- WoW Forever 1.60.x (Interface `16001`).
- [Questie](https://www.curseforge.com/wow/addons/questie) 12 with its QuestieDB addon. Every quest, giver, prerequisite and XP figure comes from Questie.

## Restrictions

Blizzard blocks addons from opening the map and the quest log in combat. A click in combat sets the waypoint only; click again after combat.

Clicking a quest replaces any map pin you placed yourself.

Only green, yellow and orange quests count toward the XP figures and the Next banner. Grey and red quests and Requires Level N rows still list where the level range allows them.

Class, profession and other quests without a zone are grouped under Other.

The dungeon line and the minimap tooltip status read the list the window built last, so they stay silent until you open the window once after logging in.

If a Questie update removes something Questie Guide relies on, it names the missing piece in chat and keeps the window closed.

## Development

Run the offline smoke test from the addon folder with Lua 5.1 or newer:

```sh
lua Tests/Smoke.lua
```

## License

MIT. See [LICENSE](LICENSE).
