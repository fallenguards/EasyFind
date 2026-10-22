local _, ns = ...

local Handlers = ns.ResultHandlers
local Shortcuts = ns.ResultShortcuts
local Icons = ns.ResultIcons
local Text = ns.ResultText

local Gestures = ns.ResultGestures

local IsAltKeyDown = IsAltKeyDown
local IsControlKeyDown = IsControlKeyDown
local select = select

-- Which gesture a row is under. A row of a kind asks the mapping
-- (Search/Results/Gestures.lua), so a user's choice moves Alt's deed to
-- any key; a row of no kind keeps the physical keys. _openInPlace: an
-- EasyFind link click cannot run a secure action, so it acts as Alt would.
function Handlers:IsSourceModifierHeld(data)
    if data and Gestures.KindOf(data) then return Gestures.WantsSource(data) end
    if Handlers._openInPlace then return true end
    return IsAltKeyDown and IsAltKeyDown() and not Shortcuts._resultShortcutActivation
end

function Handlers:IsSourceCtrlHeld(data)
    if data and Gestures.KindOf(data) then return Gestures.WantsPreview(data) end
    return IsControlKeyDown and IsControlKeyDown() and not Shortcuts._resultShortcutActivation
end

local V = Gestures.V

-- Build "Lead: target | Alt: target | ...". The lead verb localizes; modifier
-- keys (Alt/Ctrl/Shift) are physical keys and stay literal.
local function Hint(lead, clickTarget, ...)
    local s = lead .. ": " .. clickTarget
    for i = 1, select("#", ...), 2 do
        local mod, target = select(i, ...)
        s = s .. " | " .. mod .. ": " .. target
    end
    return s
end

-- The rows of no kind: one hint each, fixed.
local HINTS = {
    copyResult       = Hint(V.select, V.copyResult),
    -- Plain copyable rows (quick answers): the chord is the whole gesture.
    copyChord        = Hint("Ctrl+C", V.copyResult),
    filterResults    = Hint(V.select, V.filterResults),
    gearSet          = Hint(V.click, V.equipGearSet),
    openMap          = Hint(V.click, V.openMap),
    pinOnMap         = Hint(V.click, V.pinOnMap),
    encounter        = Hint(V.click, V.encounter),
    settings         = Hint(V.click, V.settings),
}

-- Hint shown only on the currently-selected row, replacing the normal
-- subtext so the user knows what Enter / left-click will do without
-- cluttering every other row. Returns nil for entries whose action
-- isn't worth labelling (Search navigation, settings: the row name itself
-- already tells you what happens).
function Handlers:GetActionHint(data)
    if not data then return nil end
    -- An extension's rows say what their gestures do (RegisterSearchProvider
    -- hint, or the row's own): a sentence, or { click, alt, ctrl, shift }.
    local provider = ns.Extensions and ns.Extensions.ProviderOf and ns.Extensions.ProviderOf(data)
    if provider then
        local hint = data.hint
        if hint == nil then hint = provider.hint end
        if type(hint) == "function" then
            local ok, h = pcall(hint, data)
            hint = ok and h or nil
        end
        if type(hint) == "table" then
            local s = Hint(V.click, hint.click or V.open)
            if hint.alt then s = s .. " | Alt: " .. hint.alt end
            if hint.ctrl then s = s .. " | Ctrl: " .. hint.ctrl end
            if hint.shift then s = s .. " | Shift: " .. hint.shift end
            return s
        elseif type(hint) == "string" and hint ~= "" then
            return hint
        end
    end
    -- A row of a kind: its gestures from the mapping, the user's choices in.
    local mapped = Gestures.Hint(data)
    if mapped then return mapped end
    if data.calculatorResult then return HINTS.copyResult end
    if data.copyText then return HINTS.copyChord end
    if data.quickFilterDef then return HINTS.filterResults end
    if data.gearSetID then return HINTS.gearSet end
    if data.mapSearchResult then
        if data.isZone then return HINTS.openMap end
        return HINTS.pinOnMap
    end
    if data.encounterID and data.category == "Boss" then return HINTS.encounter end
    if data.settingVariable or data.bindingAction then return HINTS.settings end
    return nil
end

-- The hint for an EasyFind LINK hovered in chat. Same localized verbs as
-- the row hints, but the gestures are the link's: a click does the action
-- (via the secure pad), Ctrl+click shows it where it lives, Shift+click
-- relinks it into chat. A macro link opens the macro (its index is the
-- receiver's own list), openers open their panel.
function Handlers:GetLinkHint(data)
    if not data then return nil end
    local click, ctrlWhere
    local opener = ns.SecureOpeners and ns.SecureOpeners.OpenKeyForData
        and ns.SecureOpeners.OpenKeyForData(data)
    if data.spellID and data.category == "Ability"
       and not Icons:IsSpellbookOnlyAbility(data) then
        click, ctrlWhere = V.cast, V.spellbook
    elseif data.mountID then
        if Icons:IsMountSummonable(data) then click, ctrlWhere = V.summon, V.journal
        else click = V.journal end
    elseif data.toyItemID then
        click, ctrlWhere = V.use, V.toybox
    elseif data.outfitID then
        click, ctrlWhere = V.wear, V.appearances
    elseif data.macroIndex then
        click = V.open
    elseif data.itemID and (data.category == "Bag" or data.catalogItem) then
        local kind = Handlers:GetBagItemActionKind(data)
        if kind == "equip" then click, ctrlWhere = V.equip, V.dressroom else click = V.use end
    elseif opener or (data.spellID and (data.category == "Talent"
           or Icons:IsSpellbookOnlyAbility(data))) then
        click = V.open
    elseif data.settingPress then
        click = V.run
    elseif data.settingVariable or data.bindingAction then
        click = V.toggle
    else
        click = V.open
    end
    local s = V.click .. ": " .. click
    if ctrlWhere then s = s .. " | Ctrl: " .. ctrlWhere end
    s = s .. " | Shift: " .. V.sendLink
    return s
end

-- Tracks the row currently displaying an action hint so we can restore
-- its normal subtext when selection moves away.
local actionHintRow

function Handlers:ClearActionHint()
    -- Pinned while its context menu is open (mirrors the row highlight).
    if actionHintRow and actionHintRow._efContextMenuHeld then return end
    if actionHintRow and actionHintRow.pathSubtext then
        actionHintRow.pathSubtext:SetText(Text:GetFlatSubtext(actionHintRow.data))
        -- Restore the THEMED subtext color; a hardcoded gray here left
        -- once-hinted rows desynced from every non-default theme.
        local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
        if theme then
            actionHintRow.pathSubtext:SetTextColor(unpack(theme.pathColor))
        end
    end
    actionHintRow = nil
end

-- Apply the action hint to a row's pathSubtext if one exists for its
-- data. Restores any previously hinted row first so only one row carries
-- a hint at a time.
function Handlers:ApplyActionHint(row)
    -- Don't move the hint off a row whose context menu is open.
    if actionHintRow and actionHintRow._efContextMenuHeld and row ~= actionHintRow then return end
    if not row or not row.pathSubtext or not row.pathSubtext:IsShown() then return end
    local hint = Handlers:GetActionHint(row.data)
    if not hint then return end
    if actionHintRow == row then return end
    Handlers:ClearActionHint()
    row.pathSubtext:SetText(hint)
    -- Warm gold on dark themes; light themes use their hover text color
    -- (the gold is unreadable on light fills).
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    if theme and theme.lightTheme then
        row.pathSubtext:SetTextColor(unpack(theme.pathColorHover))
    else
        row.pathSubtext:SetTextColor(0.85, 0.78, 0.55, 1.0)
    end
    actionHintRow = row
end

function Handlers:IsActionHintRow(row)
    return actionHintRow == row
end
