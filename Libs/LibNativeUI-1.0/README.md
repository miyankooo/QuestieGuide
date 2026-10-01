# LibNativeUI-1.0

A native UI design system for WoW Forever 1.60.x addons, shared by the miyanko addons. Every addon with a UI panel and a minimap button builds its UI from this library. That way, the addons look native to the game and recognisably come from one developer.

## Rules

- **Native first.** Every component is a Blizzard template, mixin, font object or colour object. Build a custom piece only when Blizzard has none, and style it from native parts.
- **8px grid.** Every spacing value an addon chooses is a multiple of 8: gaps, padding, margins, row heights, widths and offsets. Use the `UI.Space` and `UI.Size` tokens, or `UI.Snap()` for sizes derived from content.
- **4px font scale.** Text uses only the `UI.Font` roles, which are Blizzard font objects at 12, 16 and 20 px. Never call `SetFont` with a file or size.
- **Blizzard colours.** Colours come from `UI.Color` or another Blizzard colour object. Never write a literal `|cffRRGGBB`.
- **Native geometry is not spacing.** Offsets that compensate for a template's own art, such as InputBoxTemplate's left cap, are listed in `UI.Native`. They are the only values off the grid.

## Embedding

Each addon carries an identical copy under `Libs/LibNativeUI-1.0/`. Load it after LibStub, CallbackHandler-1.0, LibDataBroker-1.1 and LibDBIcon-1.0:

```
Libs\LibStub\LibStub.lua
Libs\CallbackHandler-1.0\CallbackHandler-1.0.lua
Libs\LibDataBroker-1.1\LibDataBroker-1.1.lua
Libs\LibDBIcon-1.0\LibDBIcon-1.0.lua
Libs\LibNativeUI-1.0\LibNativeUI-1.0.lua
```

Get it with `local UI = LibStub("LibNativeUI-1.0")`.

## Tokens

| Token | Value | Use |
|---|---|---|
| `UI.GRID` | 8 | the grid unit |
| `UI.Space.gap` | 8 | between related controls, heading to body |
| `UI.Space.padding` | 16 | inside a well or inset, to its content |
| `UI.Space.section` | 24 | between sections and groups |
| `UI.Size.row` | 24 | one list row, a checkbox, a remove button |
| `UI.Size.heading` | 16 | one section heading line |
| `UI.Size.icon` | 16 | inline icons |
| `UI.Size.button` | 128 | default bar and panel button width |
| `UI.Size.dropdown` | 160 | default dropdown width |
| `UI.Size.input` | 160 | default edit and search box width |
| `UI.Native.buttonHeight` | 22 | UIPanelButtonTemplate and MagicButtonTemplate height |
| `UI.Native.inputHeight` | 20 | InputBoxTemplate art height |
| `UI.Native.inputArt` | 5 | InputBoxTemplate's left cap outside the box (`InputBoxTemplates.xml`, Left anchor x=-5) |
| `UI.Native.scrollBarWidth` | 8 | MinimalScrollBar width |
| `UI.ScrollGutter()` | 24 | right margin a scroll frame leaves for its bar: offset 6 + bar 8 + gap 8, snapped |

| Font role | Blizzard font object | Size |
|---|---|---|
| `title` | `GameFontNormalLarge` | 16 |
| `heading` | `GameFontNormal` (gold) | 12 |
| `body` | `GameFontHighlight` (white) | 12 |
| `muted` | `GameFontDisable` (grey) | 12 |
| `display` | `GameFontNormalHuge` | 20 |

Sizes are verified in Forever's `Blizzard_Fonts_Shared/Shared/Fonts.xml`. The off-scale objects (Small 10, Med1 13, Med2/Med3 14, Large2 18, Huge3 25) are not used.

| Colour role | Blizzard colour object |
|---|---|
| `heading` | `NORMAL_FONT_COLOR` |
| `body` | `HIGHLIGHT_FONT_COLOR` |
| `muted` | `GRAY_FONT_COLOR` |
| `good` | `GREEN_FONT_COLOR` |
| `bad` | `RED_FONT_COLOR` |
| `warn` | `WARNING_FONT_COLOR` |
| `prefix` | `YELLOW_FONT_COLOR` |

`UI.Strata.window` is `HIGH` for tool windows, and `UI.Strata.dialog` is `DIALOG` for popups.

## The three areas

### 1. The UI panel

```lua
local function build()
    local window = UI.CreateWindow({
        name = "MyAddonFrame", title = "My Addon", icon = 134400,
        width = 480, height = 400,
        position = MyAddonDB.window,   -- optional: a saved table the window reads and writes
        attic = false,                 -- optional: drop the attic, or pass a height
        buttonBar = false,             -- optional: drop the button bar
    })
    UI.AddBarButton(window, "Primary", onPrimary)   -- bottom-right
    UI.AddBarButton(window, "Secondary", onSecond)  -- chained to its left
    return window
end
ns.TogglePanel = UI.CreateToggle(build)
```

What the window gives you:

- `ButtonFrameTemplate` with the portrait (the toc icon), the title without a version, the inset, the attic and the button bar.
- Strata `HIGH`, toplevel, clamped and movable.
- Escape closes it through `UISpecialFrames`, never `UIPanelWindows`.
- The close button also works in combat, through `onCloseCallback`.
- Content goes into `window.Inset`, padded by `UI.Space.padding`. A second column is `UI.CreateInset(window)`.

Building blocks:

- **Text and controls:**
  - `UI.CreateText(parent, role)`
  - `UI.CreateButton(parent, label, width)`
  - `UI.CreateCheckbox(parent, label)`
  - `UI.CreateEditBox(parent, width)`
  - `UI.CreateSearchBox(parent, width, name)`, with its typed text and hint moved to the 12 px roles
  - `UI.CreateDropdown(parent, width, name)`
  - `UI.CreateSlider(parent, width, name)`
  - `UI.CreateRemoveButton(parent)`
- **Containers:**
  - `UI.CreateInset(parent)`
  - `UI.CreateSection(parent, title)`, which gives `section.body` and `section:SetBodyHeight(h)`
  - `UI.StackBelow(frame, above, gap)`
  - `UI.CreateScroll(parent, name)`, which gives `scroll.content`
- **Tooltips:** `UI.ShowTooltip(owner, fill, anchor)` and `UI.AttachTooltip(frame, fill, anchor)`. Fill them with Blizzard's `GameTooltip_*` line helpers.

### 2. The minimap button

There is no Blizzard template for an addon minimap button on Forever, so the button stays on LibDBIcon-1.0. It works on 1.60.x and uses no missing API. Blizzard's native entry point is the Addon Compartment, and LibDBIcon registers there through `AddonCompartmentFrame:RegisterAddon`, so one launcher covers both:

```lua
UI.CreateLauncher({
    title = "My Addon", icon = 134400,
    db = MyAddonDB.minimap,
    onClick = function(button) if button == "LeftButton" then ns.TogglePanel() end end,
    tooltip = function(tooltip) GameTooltip_AddInstructionLine(tooltip, "Left-click to toggle the panel.") end,
})
```

The tooltip title is added for you. Don't also list the addon in the toc with `## AddonCompartmentFunc`, or it shows twice.

### 3. Opening and closing

- **Slash command:** `UI.RegisterSlash("MYADDON", { "/myaddon", "/ma" }, ns.TogglePanel)`.
- **Toggle:** the same `ns.TogglePanel` serves the minimap button, the addon menu and the slash command.
- **Chat output:** `UI.Print("My Addon", message)` prints the shared yellow `[My Addon]:` prefix.
- **Options page:** a page in Blizzard's options, for addons that need one. No current addon uses it yet:

```lua
local options = UI.CreateOptions("My Addon", MyAddonDB, "MYADDON")
options:Section("General")
options:Checkbox("enabled", "Enabled", "Turns the addon on or off.", true)
options:Slider("size", "Size", "How big it is.", 2, { min = 1, max = 5, step = 1 }, tostring)
options:Dropdown("mode", "Mode", "Which mode.", "a", { { "a", "Mode A" }, { "b", "Mode B" } })
options:Button("Window", "Open", ns.TogglePanel, "Opens the window.")
options:Register()
-- options:Open() opens the page, e.g. from a slash command
```

## Keeping the copies in sync

- **Reference copy:** `ChatScan/Libs/LibNativeUI-1.0/`. Every other addon carries a byte-identical copy.
- **Changing it:** edit the reference copy, raise `MINOR`, then copy the folder into every addon that embeds it. LibStub always keeps the highest `MINOR` loaded, so mixed versions never break, but the copies should not drift.
- **Checking it:** from the AddOns folder, run `shasum */Libs/LibNativeUI-1.0/LibNativeUI-1.0.lua`. It must print one hash.
- **A new addon:** copy the folder, add the toc line, and build its window, launcher and slash command from this library.
