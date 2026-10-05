# QuestieGuide

## Target

- WoW Forever 1.60.x only, `## Interface: 16001`. No client branches, no `WOW_PROJECT_*`, no compat layer for other clients or Questie versions.
- `main` holds the Forever version. `1.15.x-backup` keeps the Classic version and stays untouched.
- Verify every API against Gethe `wow-ui-source` and Ketho `BlizzardInterfaceResources`, branch `forever`, in files the Forever client loads. Verify Questie internals against the Questie 12 source.

## Questie

- The one native quest data call is `C_QuestLog.IsEliteQuest`. Questie has no elite flag, and tag 1 is Group on Forever.
- Never touch LibQuestieDB, so `## RequiredDeps` stays `Questie` alone.
- Readiness and refresh use only Questie's stable public API, `Questie.API.RegisterOnReady` and `Questie.API.RegisterForQuestUpdates`. No polling, no native quest events.
- Read Questie data only after ready. Hooks into Questie and the item tooltip post-call install from the ready callback. Post-calls run in registration order, so the guide's lines land under Questie's.
- `QUESTIE_FIELDS` lists every Questie internal the code reads. Of the query keys it lists only `parentQuest`. It checks per field, because `QuestieLoader:ImportModule` never returns nil.
- Read fields Questie reassigns through their owner, never from a cached copy: `QuestPointers`, `currentQuestlog`, `autoBlacklist`, `hiddenQuests`, `Questie.db.char.complete`.
- Clear every cache of Questie data in the `QuestieDB.RefreshAfterCorrectionApply` post-hook. Questie applies corrections after login too.
- Quest updates go through the 0.5 s debounce. On accept, Questie calls back before the quest is in `currentQuestlog`.

## Rules

- The Use Questie Level Ranges option mirrors Questie's level test without calling `AvailableQuests.IsLevelRequirementsFulfilled`, which fills Questie's per-quest cache. One deliberate difference: an outlevelled quest stays hidden (`exceedsRequiredMaxLevel`).
- Every XP sum reads the row's `countsXp`. Quest counts include every listed in-range row, including grey, red and `[Requires Level N]` rows.
- A Group-tagged elite quest shows only `[Elite (Group)]`.
- Left out on purpose: TomTom. The native user waypoint is the only map pin.
- The UI is built from LibNativeUI-1.0: `UI.Font` roles, `UI.Space`, the 8 px grid and `UI.Print`. Off-grid values are named native geometry.
- Colours come from `UI.Color` roles or Blizzard colour objects. No literal `|cff` codes. Quest names and levels use Questie's difficulty colour, and item tooltip suffixes use `Questie:Colorize`.
- The window has a fixed 680x624 size and no resize grip. Current Zone is the primary button, bottom right. Keep the minimap icon. No options page.
- No `## AddonCompartmentFunc*` toc lines. LibDBIcon adds the addon menu entry, and both would list the addon twice.

## Libraries

- `Libs/` holds tracked, unedited upstream copies. LibDBIcon-1.0, LibDataBroker-1.1 and CallbackHandler-1.0 stay for the minimap icon.
- LibNativeUI-1.0 is a byte-identical copy whose reference copy lives in ChatScan. Its `README.md` is the spec. Never edit it here. `shasum */Libs/LibNativeUI-1.0/LibNativeUI-1.0.lua` must print one hash.

## Checks

- Run `luac -p` on every Lua file after a change. The repo has no test harness.
- `QuestieGuide.lua` sits near Lua 5.1's limits of 200 active locals and 60 upvalues per function. Put single-use helpers in `do` blocks.
- Turn on `/console scriptErrors 1` before testing in game.
