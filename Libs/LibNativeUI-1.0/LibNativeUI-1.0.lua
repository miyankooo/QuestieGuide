-- LibNativeUI-1.0: a native UI design system for WoW Forever addons. Style tokens on an 8px grid, font
-- roles on a 4px scale of Blizzard's own font objects, and window, control, launcher and options builders
-- made only from Blizzard templates. Every addon embeds an identical copy; LibStub keeps the highest MINOR.
local MAJOR, MINOR = "LibNativeUI-1.0", 2
local UI = LibStub:NewLibrary(MAJOR, MINOR)
if not UI then return end

-- Every spacing value an addon chooses is a multiple of this grid.
UI.GRID = 8

-- Spacing roles: gap between related controls, padding inside a well, and the break between sections.
UI.Space = {
    gap = 8,
    padding = 16,
    section = 24,
}

-- Component slots on the grid. Blizzard templates keep their native heights centred inside a row.
UI.Size = {
    row = 24,
    heading = 16,
    icon = 16,
    button = 128,
    dropdown = 160,
    input = 160,
}

-- Geometry Blizzard's templates fix themselves. These are compensations for template art, not spacing.
UI.Native = {
    buttonHeight = 22,
    inputHeight = 20,
    inputArt = 5,
    scrollBarWidth = 8,
}

-- Font roles on Blizzard's font objects, all on the 4px scale: title 16, display 20, the rest 12.
UI.Font = {
    title = GameFontNormalLarge,
    heading = GameFontNormal,
    body = GameFontHighlight,
    muted = GameFontDisable,
    display = GameFontNormalHuge,
}

-- Colour roles on Blizzard's colour objects, so text matches the game's own UI.
UI.Color = {
    heading = NORMAL_FONT_COLOR,
    body = HIGHLIGHT_FONT_COLOR,
    muted = GRAY_FONT_COLOR,
    good = GREEN_FONT_COLOR,
    bad = RED_FONT_COLOR,
    warn = WARNING_FONT_COLOR,
    prefix = YELLOW_FONT_COLOR,
}

-- Tool windows sit above the game UI and below Blizzard's popups and menus.
UI.Strata = {
    window = "HIGH",
    dialog = "DIALOG",
}

-- Rounds a length up to the next grid step, for sizes derived from text or content.
function UI.Snap(length)
    return math.ceil(length / UI.GRID) * UI.GRID
end

-- Space a ScrollFrameTemplate needs on its right: Forever hangs MinimalScrollBar off the frame's edge.
function UI.ScrollGutter()
    return UI.Snap(SCROLL_FRAME_SCROLL_BAR_OFFSET_LEFT + UI.Native.scrollBarWidth + UI.Space.gap)
end

-- One chat line in the shared voice: the yellow "[Addon Name]:" prefix, then the message.
function UI.Print(title, message)
    print(UI.Color.prefix:WrapTextInColorCode("[" .. title .. "]:") .. " " .. message)
end

-- A left-aligned font string in one of the font roles.
function UI.CreateText(parent, role, layer)
    local text = parent:CreateFontString(nil, layer or "ARTWORK")
    text:SetFontObject(UI.Font[role or "body"])
    text:SetJustifyH("LEFT")
    return text
end

function UI.CreateButton(parent, label, width)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width or UI.Size.button, UI.Native.buttonHeight)
    button:SetText(label)
    return button
end

-- UICheckButtonTemplate shrunk from its 32px art to one row; the label keeps the template's own anchor.
function UI.CreateCheckbox(parent, label)
    local checkbox = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    checkbox:SetSize(UI.Size.row, UI.Size.row)
    checkbox.Text:SetFontObject(UI.Font.body)
    if label then checkbox.Text:SetText(label) end
    return checkbox
end

-- InputBoxTemplate draws its left cap UI.Native.inputArt px outside the box, so callers indent the box
-- by that much to line the art up with the column.
function UI.CreateEditBox(parent, width)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width or UI.Size.input, UI.Native.inputHeight)
    box:SetAutoFocus(false)
    box:SetFontObject(UI.Font.body)
    return box
end

-- SearchBoxTemplate types and hints in 10px fonts; both move to the 12px roles. The hint keeps the grey the
-- template gives it (InputBoxTemplates.xml, InputBoxInstructionsTemplate), so its colour is read before the
-- font object changes and put back after.
function UI.CreateSearchBox(parent, width, name)
    local box = CreateFrame("EditBox", name, parent, "SearchBoxTemplate")
    box:SetSize(width or UI.Size.input, UI.Native.inputHeight)
    box:SetAutoFocus(false)
    box:SetFontObject(UI.Font.body)
    local r, g, b = box.Instructions:GetTextColor()
    box.Instructions:SetFontObject(UI.Font.muted)
    box.Instructions:SetTextColor(r, g, b)
    return box
end

-- A DropdownButton on Blizzard's menu dropdown; callers fill it with SetupMenu.
function UI.CreateDropdown(parent, width, name)
    local dropdown = CreateFrame("DropdownButton", name, parent, "WowStyle1DropdownTemplate")
    dropdown:SetWidth(width or UI.Size.dropdown)
    return dropdown
end

-- The slider Blizzard's own settings use. Its Init takes a step count, not a step size.
function UI.CreateSlider(parent, width, name)
    local slider = CreateFrame("Frame", name, parent, "MinimalSliderWithSteppersTemplate")
    slider:SetWidth(width)
    return slider
end

-- The close button Blizzard uses for one row of a list, sized to the row.
function UI.CreateRemoveButton(parent)
    local button = CreateFrame("Button", nil, parent, "UIPanelCloseButtonNoScripts")
    button:SetSize(UI.Size.row, UI.Size.row)
    return button
end

function UI.CreateInset(parent)
    return CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
end

local function setBodyHeight(section, height)
    section.body:SetHeight(height)
    section:SetHeight(UI.Size.heading + UI.Space.gap + height)
end

-- A titled block: a gold heading with its body one gap below. Callers fill section.body and report its
-- height through section:SetBodyHeight.
function UI.CreateSection(parent, title)
    local section = CreateFrame("Frame", nil, parent)
    section.heading = UI.CreateText(section, "heading")
    section.heading:SetHeight(UI.Size.heading)
    section.heading:SetPoint("TOPLEFT")
    section.heading:SetPoint("TOPRIGHT")
    section.heading:SetText(title)

    section.body = CreateFrame("Frame", nil, section)
    section.body:SetPoint("TOPLEFT", section.heading, "BOTTOMLEFT", 0, -UI.Space.gap)
    section.body:SetPoint("TOPRIGHT", section.heading, "BOTTOMRIGHT", 0, -UI.Space.gap)
    section.SetBodyHeight = setBodyHeight
    setBodyHeight(section, 0)
    return section
end

-- Chains a frame below another at the same width, one section break apart unless a gap is given.
function UI.StackBelow(frame, above, gap)
    local offset = -(gap or UI.Space.section)
    frame:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, offset)
    frame:SetPoint("TOPRIGHT", above, "BOTTOMRIGHT", 0, offset)
end

-- A ScrollFrameTemplate with its scroll child. Leave UI.ScrollGutter() free on its right for the bar.
function UI.CreateScroll(parent, name)
    local scroll = CreateFrame("ScrollFrame", name, parent, "ScrollFrameTemplate")
    scroll.content = CreateFrame("Frame", nil, scroll)
    scroll.content:SetSize(1, 1)
    scroll:SetScrollChild(scroll.content)
    return scroll
end

-- Anchors GameTooltip to its owner, lets the caller fill it with Blizzard's line helpers, then shows it.
function UI.ShowTooltip(owner, fill, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    fill(GameTooltip, owner)
    GameTooltip:Show()
end

function UI.AttachTooltip(frame, fill, anchor)
    frame:SetScript("OnEnter", function(self) UI.ShowTooltip(self, fill, anchor) end)
    frame:SetScript("OnLeave", GameTooltip_Hide)
end

local function restorePosition(frame, position)
    frame:ClearAllPoints()
    if position and position.point then
        frame:SetPoint(position.point, UIParent, position.relPoint or position.point, position.x or 0, position.y or 0)
    else
        frame:SetPoint("CENTER")
    end
end

local function savePosition(frame, position)
    local point, _, relPoint, x, y = frame:GetPoint(1)
    position.point, position.relPoint, position.x, position.y = point, relPoint, x, y
end

-- A tool window on ButtonFrameTemplate: portrait, title bar, close button, inset, attic and button bar
-- come from the template. Escape closes it through UISpecialFrames and it stays out of UIPanelWindows,
-- so it never drives Blizzard's panel layout. spec: name, title, icon, width, height, and optionally
-- position (a saved table it reads and writes), attic (a height, or false to drop it) and buttonBar
-- (false to drop it).
function UI.CreateWindow(spec)
    local frame = CreateFrame("Frame", spec.name, UIParent, "ButtonFrameTemplate")
    frame:SetSize(spec.width, spec.height)
    frame:SetTitle(spec.title)
    frame:SetPortraitToAsset(spec.icon)
    frame:SetFrameStrata(UI.Strata.window)
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if spec.position then savePosition(self, spec.position) end
    end)
    restorePosition(frame, spec.position)

    if spec.attic == false then
        ButtonFrameTemplate_HideAttic(frame)
    elseif spec.attic then
        FrameTemplate_SetAtticHeight(frame, spec.attic)
    end
    if spec.buttonBar == false then ButtonFrameTemplate_HideButtonBar(frame) end

    -- The template's close button goes through HideUIPanel, which refuses insecure callers in combat.
    -- UIPanelCloseButton_OnClick asks onCloseCallback first, so the window hides itself instead.
    frame.onCloseCallback = function()
        frame:Hide()
        return false
    end

    frame:Hide()
    tinsert(UISpecialFrames, spec.name)
    return frame
end

-- A MagicButtonTemplate bar button: the first takes the bottom-right corner, later ones chain leftwards.
-- MagicButton_OnLoad runs after the zero-offset anchor so Blizzard applies its corner and neighbour
-- spacing; the template's own OnLoad ran before a Lua-made button had anchors.
function UI.AddBarButton(window, label, onClick, width)
    local button = CreateFrame("Button", nil, window, "MagicButtonTemplate")
    button:SetWidth(width or UI.Size.button)
    window.barButtons = window.barButtons or {}
    local previous = window.barButtons[#window.barButtons]
    if previous then
        button:SetPoint("RIGHT", previous, "LEFT")
    else
        button:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT")
    end
    MagicButton_OnLoad(button)
    button:SetText(label)
    button:SetScript("OnClick", onClick)
    window.barButtons[#window.barButtons + 1] = button
    return button
end

-- Builds the window on first use and flips it after that, so no frame exists until the player asks.
function UI.CreateToggle(build)
    local window
    return function()
        window = window or build()
        window:SetShown(not window:IsShown())
    end
end

-- One launcher for the minimap button and the Addon Compartment. LibDBIcon draws the minimap button and
-- adds the compartment entry through Blizzard's AddonCompartmentFrame, so both share this click handler
-- and this tooltip. spec: title, icon, db (the saved table LibDBIcon keeps its state in), onClick(button)
-- and tooltip(tooltip), which adds the lines under the title.
function UI.CreateLauncher(spec)
    local LDBIcon = LibStub("LibDBIcon-1.0")
    if LDBIcon:IsRegistered(spec.title) then return end

    local object = LibStub("LibDataBroker-1.1"):NewDataObject(spec.title, {
        type = "launcher",
        text = spec.title,
        icon = spec.icon,
        OnClick = function(_, button) spec.onClick(button) end,
        OnTooltipShow = function(tooltip)
            GameTooltip_SetTitle(tooltip, spec.title)
            spec.tooltip(tooltip)
        end,
    })
    LDBIcon:Register(spec.title, object, spec.db)
    LDBIcon:AddButtonToCompartment(spec.title)
end

-- Blizzard reads SLASH_<KEY>1..n and SlashCmdList[KEY].
function UI.RegisterSlash(key, commands, handler)
    for index, command in ipairs(commands) do
        _G["SLASH_" .. key .. index] = command
    end
    SlashCmdList[key] = handler
end

local Options = {}
Options.__index = Options

local function addSetting(options, key, label, varType, default)
    local variable = options.prefix .. "_" .. key:upper()
    return Settings.RegisterAddOnSetting(options.category, variable, key, options.db, varType, label, default)
end

function Options:Section(title)
    self.layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(title))
end

function Options:Checkbox(key, label, tooltip, default)
    local setting = addSetting(self, key, label, Settings.VarType.Boolean, default)
    Settings.CreateCheckbox(self.category, setting, tooltip)
    return setting
end

-- formatter turns the value into the label Blizzard prints right of the slider.
function Options:Slider(key, label, tooltip, default, range, formatter)
    local setting = addSetting(self, key, label, Settings.VarType.Number, default)
    local sliderOptions = Settings.CreateSliderOptions(range.min, range.max, range.step)
    sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatter)
    Settings.CreateSlider(self.category, setting, sliderOptions, tooltip)
    return setting
end

-- choices is a list of { value, label } pairs; the value type follows the default.
function Options:Dropdown(key, label, tooltip, default, choices)
    local varType = type(default) == "number" and Settings.VarType.Number or Settings.VarType.String
    local setting = addSetting(self, key, label, varType, default)
    local function buildChoices()
        local container = Settings.CreateControlTextContainer()
        for _, choice in ipairs(choices) do container:Add(choice[1], choice[2]) end
        return container:GetData()
    end
    Settings.CreateDropdown(self.category, setting, buildChoices, tooltip)
    return setting
end

function Options:Button(label, buttonText, onClick, tooltip)
    self.layout:AddInitializer(CreateSettingsButtonInitializer(label, buttonText, onClick, tooltip, true))
end

function Options:Register()
    Settings.RegisterAddOnCategory(self.category)
end

function Options:Open()
    Settings.OpenToCategory(self.category:GetID())
end

-- An options page in Blizzard's Settings, vertical layout, bound to a saved-variables table. prefix
-- namespaces the setting variables (e.g. "CHATSCAN"). Add rows in display order, then call Register.
function UI.CreateOptions(title, db, prefix)
    local category, layout = Settings.RegisterVerticalLayoutCategory(title)
    return setmetatable({ category = category, layout = layout, db = db, prefix = prefix }, Options)
end
