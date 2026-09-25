# QuestieGuide — Memory

Updated 2026-09-25 after the dual-client port with native UI and Questie-only quest data (decision: every addon in the folder supports both clients, and quest data comes only from Questie). Verified against Gethe `forever` @ `bd2470a` (1.60.1.70009), Gethe `classic_era` @ `33e177d` (1.15.9.69722), the matching Ketho dumps, Questie 11.37.1 (installed), Questie master @ `4001614` and QuestieDB master @ `b6f5b07`. Nothing has run in a client.

## Current state

Lists every quest you can pick up now, grouped by zone, from Questie's database. On top of that list it adds:

- Trip XP including follow-ups, and a "Next:" banner.
- Status labels and a chain tooltip that jumps to the step you can do.
- A map jump to the quest giver: through TomTom when it's installed, otherwise a native waypoint on 1.60.
- Filters, sorting, a completed-quests section, item-tooltip lines and a level-up toast.
- A minimap button, the Addon Compartment on Forever, `/qg`, a key binding, and click-through from Questie's map icons.

| Item | State |
|---|---|
| Working tree | 1.1.0, both clients from one toc, `## Interface: 11509, 16001`, `## Author: miyanko`, `## Dependencies: Questie`, Addon Compartment fields |
| Git | Committed and pushed on 2026-09-25: `main` = `origin/main`. The last Era-only release is 1.0.0 at `14f078c` |

Quest data comes only from Questie:

- There's no native quest-data provider, and none is planned.
- Native calls are limited to UI integration and the player's own state: the quest log, the map and waypoint, tooltips, chat links, the green range and the completion flag.
- 31 Questie internals are checked once, when `Questie.started` is set. The check has to be per field, because `ImportModule` returns an empty module and never nil.
  - If one of the 6 required internals is missing, the window stays closed and the message names what's missing.
  - The 25 optional ones each switch off one named feature.
- All internals exist in both 11.37.1 and master.

Client branches, grouped in the `Client` section of `QuestieGuide.lua` (around line 145):

| Branch | 1.15.9 | 1.60.1 |
|---|---|---|
| Quest log | `QuestLogFrame` + `QuestLog_SetSelection` | `QuestMapFrame_OpenToQuestDetails` |
| Green range | `GetQuestGreenRange` | `UnitQuestTrivialLevelRange("player")` |
| Waypoint without TomTom | none | `C_Map.SetUserWaypoint` + `C_SuperTrack`, each guarded |
| Item tooltip | `OnTooltipSetItem` script | `TooltipDataProcessor` |
| Launcher | minimap button | minimap button + Addon Compartment |

Native UI:

- The window is `ButtonFrameTemplate` with a portrait, laid out like ChannelFrame: a settings column in an `InsetFrameTemplate` and the list in the template's `.Inset`.
- The list uses `ScrollFrameTemplate`, which gives each client its own scroll bar.
- `WowStyle1DropdownTemplate`, `MinimalSliderWithSteppersTemplate`, `SearchBoxTemplate` (in the attic, like AddonList), `UIPanelButtonTemplate` and `PanelResizeButtonTemplate`.
- Blizzard font objects, and the `GameTooltip_*` helpers for tooltips.

Fixed in the port:

- `ChatEdit_*` is replaced by `ChatFrameUtil`.
- `C_SuperTrack` has its own guard.
- The stale comments are corrected.
- The dead `SetMinResize` and `QuestieLib.GetTbcLevel` paths are removed.
- `{-1,-1}` dungeon spawns no longer show coordinates or set a waypoint.
- A zone is no longer paired with another zone's spawn.

## Blockers, issues, challenges

1. Blocker for 1.60: the installed Questie 11.37.1 has no Forever toc. Forever needs Questie 12 (`Questie_Camelot.toc`, pre-release only) plus QuestieDB, and neither is installed. On Vanilla, Questie 12 also needs QuestieDB.
2. The addon depends on undocumented Questie internals, and Questie 12's QuestieDB contract is still moving. The LibQuestieDB return shapes were read from source only.
3. Unverified: does opening the modern world map and quest log from addon code taint `WorldMapFrame` in combat?
4. Unverified: are QuestieDB's Forever coordinates in Forever map space? Setting a waypoint also replaces the player's own.
5. Questie's docs report that the 69913 beta can lose saved variables on a cold start.
6. Layout at the 640x480 minimum, the Era trim scroll bar in the inset, and the portrait in Era's ring are all unseen.
7. There's no `_classic_era_` install. The installed beta is 69913, the source is 70009.

## Next steps

1. Install Questie 12 and QuestieDB in `_classic_beta_`. Run `/console scriptErrors 1` first.

Both clients:

- [ ] `/reload`: no errors and no "Questie has no …" lines. `/qg` before Questie is ready says it's still loading.
- [ ] The window shows the settings column on the left, the list on the right, search at top right, and buttons and grip at bottom right. It resizes down to 640x480, and size and position survive `/reload`.
- [ ] The dropdowns, sliders and "Use Questie Level Ranges" work. Search filters the list and the clear button resets it.
- [ ] Clicking an Available quest opens the map at the giver, with the Questie pin pulsing. Clicking a Missing Pre-Quest row jumps to the prerequisite.
- [ ] Right-click → "Link in chat" inserts the link. A Questie map-icon click opens the guide, except while a chat box is open.
- [ ] Quest items in bags show their status line once.

Era, with Questie 11.37.1:

- [ ] Classic frame art and trim scroll bar. An In Questlog row opens `QuestLogFrame` on that quest. A dungeon giver shows no coordinates.

Forever, with Questie 12 and QuestieDB:

- [ ] Mainline art and the minimal scroll bar. The compartment lists Questie Guide.
- [ ] Without TomTom, an Available quest sets the native pin and beacon. `/dump C_Map.HasUserWaypoint(), C_SuperTrack.IsSuperTrackingUserWaypoint()` prints `true true`, and the pin sits on the NPC. This settles issue 4.
- [ ] An In Questlog row opens the quest map log on that quest.
- [ ] Open the guide in combat and click a row: no "action blocked". This settles issue 3.
- [ ] Fully quit and restart: filters and position survive. This settles issue 5.
