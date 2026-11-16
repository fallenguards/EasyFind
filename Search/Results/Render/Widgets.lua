local _, ns = ...

local Utils = ns.Utils
local Render = ns.ResultRender
local Calculator = ns.Calculator
local Icons = ns.ResultIcons

local sformat = Utils.sformat
local mfloor = Utils.mfloor
local AbbrevBinding = Render.AbbrevBinding
local SetClippedText = Render.SetClippedText

function Render.SettingsWidget(resultRow, data, entry)
    -- Setting state visualization. Checkbox: check/uncheck atlas
    -- (toggle inline via PostClick). Slider: actual draggable
    -- slider widget with value label. Dropdown/other: current
    -- value as muted text (click opens panel to edit).
    local isKeybindEntry = data and data.settingType == "keybind" and data.bindingAction
    local blizzSearch = ns.BlizzOptionsSearch
    if isKeybindEntry and not entry.isPathNode and not data.accountKeybind
       and blizzSearch and blizzSearch:IsPerformableBinding(data.bindingAction) then
        -- Merged toggle row: clicking performs the binding, so no inline
        -- capture buttons. Current keys stay visible in the row tooltip;
        -- binds change via Alt+click (Settings > Keybindings deep link).
        resultRow.settingKeybindGroup:Hide()
        local isOn = blizzSearch:GetToggleBindingState(data.bindingAction)
        resultRow.settingState:SetShown(isOn ~= nil)
        resultRow.settingCheck:SetShown(isOn == true)
        resultRow.amountText:Hide()
        if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
        if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
        if isOn ~= nil then
            resultRow.text:SetPoint("RIGHT", resultRow.settingState, "LEFT", -4, 0)
        end
    elseif isKeybindEntry and not entry.isPathNode then
        -- Keybinding row: two inline buttons showing current
        -- primary/alternate keys. Refresh function lets the
        -- buttons re-read GetBindingKey after a capture/clear.
        local action = data.bindingAction
        local kb1 = resultRow.settingKeybind1
        local kb2 = resultRow.settingKeybind2
        -- EasyFind's own binds: one key, kept by EasyFind.
        local account = data.accountKeybind == true
        local function refresh()
            if account then
                kb1:SetText(AbbrevBinding(EasyFind:GetAccountKeybind(action)))
                return
            end
            local k1, k2 = GetBindingKey(action)
            kb1:SetText(AbbrevBinding(k1))
            kb2:SetText(AbbrevBinding(k2))
        end
        kb1._bindingAction = action
        kb1._refresh = refresh
        kb1._accountKeybind = account
        kb2._bindingAction = action
        kb2._refresh = refresh
        kb2._accountKeybind = account
        kb2:SetShown(not account)
        refresh()
        resultRow.settingKeybindGroup:Show()
        if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
        if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
        resultRow.settingState:Hide()
        resultRow.settingCheck:Hide()
        resultRow.amountText:Hide()
        resultRow.text:SetPoint("RIGHT", resultRow.settingKeybindGroup, "LEFT", -4, 0)
    elseif data and data.settingVariable and not entry.isPathNode then
        if resultRow.settingKeybindGroup then resultRow.settingKeybindGroup:Hide() end
        local settingType = data.settingType
        if settingType == "checkboxSlider" and data.cbVariable and data.sliderVariable then
            -- Combined widget: checkbox state + slider in one row
            -- (mirrors Blizzard's CreateSettingsCheckboxSliderInitializer
            -- visual e.g. "Use Search Scale" with the % slider).
            local cbVal = ns.ResultRows:ReadSettingVariable(data.cbVariable)
            local isOn = cbVal == true or cbVal == "1" or cbVal == 1
            resultRow.settingState:Show()
            resultRow.settingCheck:SetShown(isOn)
            resultRow.amountText:Hide()
            if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end

            local sliderVar = data.sliderVariable
            local rawVal = ns.ResultRows:ReadSettingVariable(sliderVar)
            local numVal = tonumber(rawVal) or data.settingMin or 0
            local sMin = data.settingMin or 0
            local sMax = data.settingMax or 1
            local stepVal = data.settingStep or 1
            if sMax <= sMin then sMax = sMin + 1 end
            local slider = resultRow.settingSlider
            slider._settingVar = sliderVar
            slider._settingFormatter = data.settingFormatter
            slider._updating = true
            slider:SetMinMaxValues(sMin, sMax)
            slider:SetValueStep(stepVal)
            slider:SetValue(numVal)
            slider._updating = false

            if not data.settingFormatter
               and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetFormatterForVariable then
                local fmt = ns.BlizzOptionsSearch.GetFormatterForVariable(sliderVar)
                if fmt then data.settingFormatter = fmt end
            end
            local displayVal
            if data.settingFormatter then
                local fok, formatted = pcall(data.settingFormatter, numVal)
                if fok and formatted ~= nil then
                    local ft = type(formatted)
                    if ft == "string" and formatted ~= "" then displayVal = formatted
                    elseif ft == "number" then
                        displayVal = (formatted == mfloor(formatted))
                            and tostring(mfloor(formatted))
                            or sformat("%.2f", formatted)
                    end
                end
            end
            if not displayVal then
                displayVal = (numVal == mfloor(numVal))
                    and tostring(mfloor(numVal))
                    or sformat("%.2f", numVal)
            end
            resultRow.settingSliderValue:SetText(displayVal)

            -- The checkbox gates the slider, matching Blizzard's composite
            -- control: unchecked means grayed out and unmovable.
            slider:EnableMouse(isOn)
            if resultRow.settingStepBack then
                resultRow.settingStepBack:SetEnabled(isOn)
                resultRow.settingStepFwd:SetEnabled(isOn)
            end
            resultRow.settingSliderGroup:SetAlpha(isOn and 1 or 0.45)

            -- Slider group sits to the LEFT of the checkbox
            -- so both fit on the right side of the row.
            resultRow.settingSliderGroup:ClearAllPoints()
            resultRow.settingSliderGroup:SetPoint("RIGHT", resultRow.settingState, "LEFT", -6, 0)
            resultRow.settingSliderGroup:Show()

            resultRow.text:SetPoint("RIGHT", resultRow.settingSliderGroup, "LEFT", -4, 0)
        elseif settingType == "checkboxDropdown" and data.cbVariable and data.dropdownVariable then
            -- Combined widget: checkbox state + mode dropdown in one row
            -- (mirrors Blizzard's checkbox+dropdown control, e.g. Click
            -- to Move with its "Only when moving" style mode picker).
            local cbVal = ns.ResultRows:ReadSettingVariable(data.cbVariable)
            local isOn = cbVal == true or cbVal == "1" or cbVal == 1
            local optimistic = ns.Results and ns.Results._settingOptimistic
            if optimistic and optimistic.var == data.cbVariable then
                isOn = optimistic.isOn
            end
            resultRow.settingState:Show()
            resultRow.settingCheck:SetShown(isOn)
            resultRow.amountText:Hide()
            if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end

            local rawVal = ns.ResultRows:ReadSettingVariable(data.dropdownVariable)
            local val = rawVal ~= nil and tostring(rawVal) or ""
            if not data.settingOptions
               and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetOptionsForVariable then
                local opts = ns.BlizzOptionsSearch.GetOptionsForVariable(data.dropdownVariable or data.settingVariable)
                if opts then data.settingOptions = opts end
            end
            local optList = type(data.settingOptions) == "table" and data.settingOptions or nil
            if optList and rawVal ~= nil then
                for oi = 1, #optList do
                    local o = optList[oi]
                    if o.value == rawVal or tostring(o.value) == tostring(rawVal) then
                        val = o.label or val
                        break
                    end
                end
            end
            if resultRow.SetSettingDropdownText then
                resultRow:SetSettingDropdownText(val)
            end
            -- The checkbox gates the dropdown, matching Blizzard's control.
            local ddGroup = resultRow.settingDropdownGroup
            ddGroup:SetAlpha(isOn and 1 or 0.45)
            if resultRow.settingDropdownPrev then
                resultRow.settingDropdownPrev:SetEnabled(isOn)
                resultRow.settingDropdownNext:SetEnabled(isOn)
            end
            if resultRow.settingDropdownLabel then
                resultRow.settingDropdownLabel:SetEnabled(isOn)
            end
            ddGroup:ClearAllPoints()
            ddGroup:SetPoint("RIGHT", resultRow.settingState, "LEFT", -6, 0)
            ddGroup:Show()
            resultRow.text:SetPoint("RIGHT", ddGroup, "LEFT", -4, 0)
        elseif settingType == "checkbox" then
            local isOn
            local optimistic = ns.Results and ns.Results._settingOptimistic
            if optimistic and optimistic.var == data.settingVariable then
                -- Just-toggled value, shown before GetValue catches up.
                isOn = optimistic.isOn
            else
                -- The Settings object's logical value first (an inverted setting
                -- reads false while its raw CVar is "1"), the raw CVar only for
                -- variables with no registered setting.
                local v = ns.ResultRows:ReadSettingVariable(data.settingVariable)
                isOn = v == true or v == "1" or v == 1
            end
            resultRow.settingState:Show()
            resultRow.settingCheck:SetShown(isOn)
            resultRow.amountText:Hide()
            if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
            if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
            -- Re-anchor text RIGHT to settingState so the row name
            -- truncates at the checkbox instead of overlapping it.
            resultRow.text:SetPoint("RIGHT", resultRow.settingState, "LEFT", -4, 0)
        elseif settingType == "slider" and data.settingMin and data.settingMax then
            local rawVal = ns.ResultRows:ReadSettingVariable(data.settingVariable)
            local numVal = tonumber(rawVal) or data.settingMin

            local sMin, sMax = data.settingMin, data.settingMax
            local stepVal = data.settingStep or 1
            if sMax <= sMin then sMax = sMin + 1 end
            local slider = resultRow.settingSlider
            slider._settingVar = data.settingVariable
            slider._settingFormatter = data.settingFormatter
            slider._updating = true
            slider:SetMinMaxValues(sMin, sMax)
            slider:SetValueStep(stepVal)
            slider:SetValue(numVal)
            slider._updating = false
            -- Pooled rows: clear any gating a checkboxSlider render left.
            slider:EnableMouse(true)
            if resultRow.settingStepBack then
                resultRow.settingStepBack:SetEnabled(true)
                resultRow.settingStepFwd:SetEnabled(true)
            end
            resultRow.settingSliderGroup:SetAlpha(1)
            resultRow.settingSliderGroup:ClearAllPoints()
            resultRow.settingSliderGroup:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
            resultRow.settingSliderGroup:Show()

            -- Curated SETTINGS_DATA rows don't ship with a
            -- formatter; pull from the live registry on demand
            -- so the inline value matches Blizzard's panel
            -- (Mouse Look Speed raw 180 -> displayed "5.5").
            if not data.settingFormatter
               and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetFormatterForVariable then
                local fmt = ns.BlizzOptionsSearch.GetFormatterForVariable(data.settingVariable)
                if fmt then data.settingFormatter = fmt end
            end
            local displayVal
            if data.settingFormatter then
                local fok, formatted = pcall(data.settingFormatter, numVal)
                if fok and formatted ~= nil then
                    local ft = type(formatted)
                    if ft == "string" and formatted ~= "" then
                        displayVal = formatted
                    elseif ft == "number" then
                        displayVal = (formatted == mfloor(formatted))
                            and tostring(mfloor(formatted))
                            or sformat("%.2f", formatted)
                    end
                end
            end
            if not displayVal then
                if numVal == mfloor(numVal) then
                    displayVal = tostring(mfloor(numVal))
                else
                    displayVal = sformat("%.2f", numVal)
                end
            end
            resultRow.settingSliderValue:SetText(displayVal)

            resultRow.settingState:Hide()
            resultRow.settingCheck:Hide()
            resultRow.amountText:Hide()
            if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
            resultRow.text:SetPoint("RIGHT", resultRow.settingSliderGroup, "LEFT", -4, 0)
        else
            -- Dropdown / other: show current value as text (an empty string is
            -- a real value: Graphics Card "" = Auto Detect).
            local rawVal = ns.ResultRows:ReadSettingVariable(data.settingVariable)
            local val = rawVal ~= nil and tostring(rawVal) or nil
            -- Lazily cache the option list so subsequent renders
            -- can translate raw values (often opaque ints) into
            -- the localized label the dropdown actually shows.
            if data.settingType == "dropdown" and not data.settingOptions
               and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetOptionsForVariable then
                local opts = ns.BlizzOptionsSearch.GetOptionsForVariable(data.settingVariable)
                if opts then data.settingOptions = opts end
            end
            local optList = (data.settingType == "dropdown" and type(data.settingOptions) == "table")
                and data.settingOptions or nil
            if optList and rawVal ~= nil then
                for oi = 1, #optList do
                    local o = optList[oi]
                    if o.value == rawVal or tostring(o.value) == tostring(rawVal) then
                        val = o.label or val
                        break
                    end
                end
            end
            if optList and #optList > 0 then
                -- Inline dropdown widget: paddle arrows + center
                -- button styled like the in-game Settings dropdown.
                if resultRow.SetSettingDropdownText then
                    resultRow:SetSettingDropdownText(val or "")
                else
                    resultRow.settingDropdownLabel:SetText(val or "")
                end
                -- Pooled rows: clear gating and anchoring a
                -- checkboxDropdown render left behind.
                resultRow.settingDropdownGroup:SetAlpha(1)
                if resultRow.settingDropdownPrev then
                    resultRow.settingDropdownPrev:SetEnabled(true)
                    resultRow.settingDropdownNext:SetEnabled(true)
                end
                if resultRow.settingDropdownLabel then
                    resultRow.settingDropdownLabel:SetEnabled(true)
                end
                resultRow.settingDropdownGroup:ClearAllPoints()
                resultRow.settingDropdownGroup:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                resultRow.settingDropdownGroup:Show()
                resultRow.amountText:Hide()
                resultRow.text:SetPoint("RIGHT", resultRow.settingDropdownGroup, "LEFT", -4, 0)
            else
                -- No enumerable options: muted text fallback. Click
                -- opens the panel via OpenSettingNoClose.
                if val and val ~= "" then
                    resultRow.amountText:SetText("|cFFAAAAaa" .. val .. "|r")
                    resultRow.amountText:ClearAllPoints()
                    resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                    resultRow.amountText:Show()
                end
                if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
            end
            resultRow.settingState:Hide()
            resultRow.settingCheck:Hide()
            if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
        end
    else
        resultRow.settingState:Hide()
        resultRow.settingCheck:Hide()
        if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
        if resultRow.settingKeybindGroup then resultRow.settingKeybindGroup:Hide() end
        if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
    end


end

-- A learned recipe's craft controls, as its profession window has them:
-- a count, Create, Create All. Shown on the hovered or selected row, at
-- the right where the name ended; the name stops short of them.
local CRAFT_H, CRAFT_GAP, CRAFT_MIN_NAME = 20, 4, 60
local craft = { shown = {} }

local function RightPoint(region)
    for i = 1, region:GetNumPoints() do
        local point, rel, relPoint, x, y = region:GetPoint(i)
        if point == "RIGHT" then return { rel, relPoint, x, y } end
    end
end

-- Where a name ends without the controls: its edge now, unless that is
-- still their own push (a pass that left the name be), which goes back to
-- the edge it was pushed from. Taken as the edge, the push stacked: each
-- redraw slid the name and controls further left.
local function TakeBack(region, edge, pushed)
    local now = RightPoint(region)
    if not (edge and pushed and now and now[1] == pushed[1] and now[2] == pushed[2]
            and math.abs(now[3] - pushed[3]) < 0.5) then
        return now
    end
    region:SetPoint("RIGHT", edge[1], edge[2], edge[3], edge[4])
    return edge
end

local function CraftCount(row)
    local n = tonumber(row.craftBox:GetText())
    return n and n > 0 and n or 1
end

local function Refocus()
    local frame = ns.Search:GetSearchFrame()
    local nav = ns.Search:GetNavFrame()
    if not (frame and frame.editBox) or (nav and nav:IsKeyboardEnabled()) then return end
    frame.editBox.blockFocus = nil
    frame.editBox:SetFocus()
end

local function SelectedRow()
    local sel = ns.Search:GetSelectedIndex()
    return sel > 0 and ns.Results:RowFrame(sel) or nil
end

local function BuildCraft(row)
    local g = CreateFrame("Frame", nil, row)
    g:SetFrameLevel(row:GetFrameLevel() + 5)
    g:SetHeight(CRAFT_H)
    g:Hide()
    local minus = ns.CreateModernButton(g, "-", 18, CRAFT_H)
    minus:SetPoint("LEFT", g, "LEFT", 0, 0)
    local shell = CreateFrame("Frame", nil, g)
    shell:SetSize(30, CRAFT_H)
    shell:SetPoint("LEFT", minus, "RIGHT", 2, 0)
    local inset = ns.CreateRingedWell(shell, 5)
    ns.PaintInputWell(shell)
    local box = CreateFrame("EditBox", nil, inset)
    box:SetPoint("TOPLEFT", 2, 0)
    box:SetPoint("BOTTOMRIGHT", -2, 0)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetJustifyH("CENTER")
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(3)
    box:SetText("1")
    local plus = ns.CreateModernButton(g, "+", 18, CRAFT_H)
    plus:SetPoint("LEFT", shell, "RIGHT", 2, 0)
    local create = ns.CreateModernButton(g, _G["CREATE_PROFESSION"] or "Create", 60, CRAFT_H)
    create:SetPoint("LEFT", plus, "RIGHT", CRAFT_GAP, 0)
    local all = ns.CreateModernButton(g, "", 80, CRAFT_H)
    all:SetPoint("LEFT", create, "RIGHT", CRAFT_GAP, 0)
    row.craftGroup, row.craftBox, row.craftCreate, row.craftAll = g, box, create, all

    local function Step(delta)
        local most = math.max(1, row._craftMost or 1)
        box:SetText(tostring(math.max(1, math.min(most, CraftCount(row) + delta))))
    end
    minus:SetScript("OnClick", function() Step(-1) Refocus() end)
    plus:SetScript("OnClick", function() Step(1) Refocus() end)
    create:SetScript("OnClick", function()
        ns.ResultHandlers:CraftRecipe(row.data, CraftCount(row))
        Refocus()
    end)
    all:SetScript("OnClick", function()
        ns.ResultHandlers:CraftRecipe(row.data, row._craftMost)
        Refocus()
    end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        ns.ResultHandlers:CraftRecipe(row.data, CraftCount(row))
        Refocus()
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        Refocus()
    end)
    Utils.ReleaseFocusOnOutsideClick(box)
    local function Recheck() Render.LayoutCraft(row) end
    for _, control in ipairs({ minus, plus, create, all, box }) do control:HookScript("OnLeave", Recheck) end
    row:HookScript("OnEnter", Recheck)
    row:HookScript("OnLeave", Recheck)
end

craft.events = CreateFrame("Frame")
craft.events:SetScript("OnEvent", function()
    for row in pairs(craft.shown) do Render.LayoutCraft(row) end
end)

-- The hovered control's leave fires inside the hide: a show from there
-- left the later buttons unseen (EasyFindDev craftrow, 2026-11-17).
local function HideCraft(row)
    craft.hiding = true
    row.craftGroup:Hide()
    craft.hiding = nil
    craft.shown[row] = nil
    if not next(craft.shown) then craft.events:UnregisterEvent("BAG_UPDATE_DELAYED") end
end

local function Lay(row)
    local g = row.craftGroup
    if not (g and row._craftText) then return end
    local anchor = TakeBack(row.text, row._craftText, row._craftPush) or row._craftText
    local sub = row._craftSub and (TakeBack(row.pathSubtext, row._craftSub, row._craftSubPush) or row._craftSub)
    row._craftText, row._craftSub, row._craftPush, row._craftSubPush = anchor, sub, nil, nil
    local data = row.data
    local want = row:IsShown() and ns.ResultHandlers.CanCraft(data)
        and (row:IsMouseOver() or row == SelectedRow() or g:IsMouseOver() or row.craftBox:HasFocus())
    local most = want and ns.ResultHandlers.CraftableCount(data.professionRecipeID)
    if most then
        row._craftMost = most
        row.craftCreate:SetEnabled(most > 0)
        row.craftAll:SetEnabled(most > 0)
        row.craftAll:SetText((_G["PROFESSIONS_CREATE_ALL_FORMAT"] or "%s [%d]")
            :format(_G["PROFESSIONS_CREATE_ALL"] or "Create All", most))
        -- The narrowest window keeps a stub of the name; the labels give way.
        local fixed = 18 + 2 + 30 + 2 + 18 + CRAFT_GAP * 2
        local room = math.max(80, row:GetWidth() - CRAFT_MIN_NAME - 40 - fixed)
        ns.FitButtonRow({ row.craftCreate, row.craftAll }, room, CRAFT_GAP, 36)
        local width = fixed + row.craftCreate:GetWidth() + row.craftAll:GetWidth()
        g:SetWidth(width)
        g:ClearAllPoints()
        g:SetPoint("RIGHT", anchor[1], anchor[2], anchor[3], 0)
        row.text:SetPoint("RIGHT", anchor[1], anchor[2], anchor[3] - width - 6, anchor[4])
        row._craftPush = { anchor[1], anchor[2], anchor[3] - width - 6 }
        if sub then
            row.pathSubtext:SetPoint("RIGHT", sub[1], sub[2], sub[3] - width - 6, sub[4])
            row._craftSubPush = { sub[1], sub[2], sub[3] - width - 6 }
        end
        if not g:IsShown() then
            g:Show()
            craft.shown[row] = true
            craft.events:RegisterEvent("BAG_UPDATE_DELAYED")
        end
    elseif g:IsShown() then
        HideCraft(row)
    else
        return
    end
    Render.SetClippedText(row.text, row.text._unclippedText)
    if row.pathSubtext._unclippedText then Render.SetClippedText(row.pathSubtext, row.pathSubtext._unclippedText) end
end

-- Show or hide one row's controls by hover, selection and the bags. A
-- control disabled under the mouse fires its leave inside SetEnabled,
-- still enabled: a layout from there ran again until the stack overflowed
-- (Create All's last craft, 2026-11-17). One layout at a time.
function Render.LayoutCraft(row)
    if craft.hiding or craft.laying then return end
    craft.laying = true
    xpcall(Lay, Utils.ErrorHandler, row)
    craft.laying = nil
end

-- At each render: where the name ends with no controls, kept so they
-- can take that edge and give it back.
function Render.ApplyCraftControls(resultRow, entry)
    local data = entry.data
    local same = resultRow._craftData == data
    if not same and resultRow.craftBox then resultRow.craftBox:SetText("1") end
    resultRow._craftData = data
    local edge = TakeBack(resultRow.text, resultRow._craftText, resultRow._craftPush)
    local subEdge = TakeBack(resultRow.pathSubtext, resultRow._craftSub, resultRow._craftSubPush)
    resultRow._craftPush, resultRow._craftSubPush = nil, nil
    local craftable = data and data.professionRecipeID and not entry.isPathNode and ns.ResultHandlers.CanCraft(data)
    -- A redraw of the same recipe keeps its controls up: hidden and shown
    -- under the mouse, a press was lost and the row's tooltip flashed.
    if resultRow.craftGroup and not (same and craftable) then HideCraft(resultRow) end
    if not craftable then
        resultRow._craftText, resultRow._craftSub = nil, nil
        return
    end
    resultRow._craftText = edge
    resultRow._craftSub = resultRow.pathSubtext:IsShown() and subEdge or nil
    if not resultRow.craftGroup then BuildCraft(resultRow) end
    Render.LayoutCraft(resultRow)
end

function Render.CalculatorRow(self, resultRow, data, state)
    SetClippedText(resultRow.text, "")
    resultRow.amountText:Hide()
    if resultRow.pathSubtext then resultRow.pathSubtext:Hide() end
    if resultRow.flatCatIcon then resultRow.flatCatIcon:Hide() end
    Icons:SetRowIcon(resultRow, "hidden", nil, state.rowIconSize)

    if data.calculatorResult then
        resultRow.calcCard:ClearAllPoints()
        resultRow.calcCard:SetPoint("TOPLEFT", resultRow, "TOPLEFT", 4, -3)
        resultRow.calcCard:SetPoint("BOTTOMRIGHT", resultRow, "BOTTOMRIGHT", -4, 3)
        resultRow.calcCard:Show()
        if resultRow._efCalcGen ~= ns.uiThemeGeneration then
            resultRow._efCalcGen = ns.uiThemeGeneration
            ns.ResultRows.ApplyCalcCardTheme(resultRow)
        end

        resultRow.calcDivider:ClearAllPoints()
        resultRow.calcDivider:SetPoint("TOP", resultRow.calcCard, "TOP", 0, -1)
        resultRow.calcDivider:SetPoint("BOTTOM", resultRow.calcCard, "BOTTOM", 0, 1)
        resultRow.calcDivider:Show()

        resultRow.calcArrowText:ClearAllPoints()
        resultRow.calcArrowText:SetPoint("CENTER", resultRow.calcCard, "CENTER", 0, 0)
        resultRow.calcArrowText:Show()

        resultRow.calcDividerTop:ClearAllPoints()
        resultRow.calcDividerTop:SetPoint("TOP", resultRow.calcCard, "TOP", 0, -1)
        resultRow.calcDividerTop:SetPoint("BOTTOM", resultRow.calcArrowText, "TOP", 0, 3)
        resultRow.calcDividerTop:Show()

        resultRow.calcDividerBottom:ClearAllPoints()
        resultRow.calcDividerBottom:SetPoint("TOP", resultRow.calcArrowText, "BOTTOM", 0, -3)
        resultRow.calcDividerBottom:SetPoint("BOTTOM", resultRow.calcCard, "BOTTOM", 0, 1)
        resultRow.calcDividerBottom:Show()

        resultRow.calcExpressionText:ClearAllPoints()
        resultRow.calcExpressionText:SetPoint("LEFT", resultRow.calcCard, "LEFT", 12, 0)
        resultRow.calcExpressionText:SetPoint("RIGHT", resultRow.calcDivider, "LEFT", -22, 0)
        SetClippedText(resultRow.calcExpressionText, data.calculatorExpressionShown or data.calculatorExpression or data.name or "")
        resultRow.calcExpressionHighlight:ClearAllPoints()
        resultRow.calcExpressionHighlight:SetPoint("TOPLEFT", resultRow.calcCard, "TOPLEFT", 1, 0)
        resultRow.calcExpressionHighlight:SetPoint("BOTTOMRIGHT", resultRow.calcDivider, "BOTTOMLEFT", -1, 1)
        resultRow.calcExpressionFlash:ClearAllPoints()
        resultRow.calcExpressionFlash:SetPoint("TOPLEFT", resultRow.calcExpressionHighlight, "TOPLEFT")
        resultRow.calcExpressionFlash:SetPoint("BOTTOMRIGHT", resultRow.calcExpressionHighlight, "BOTTOMRIGHT")

        resultRow.calcResultText:ClearAllPoints()
        resultRow.calcResultText:SetPoint("LEFT", resultRow.calcDivider, "RIGHT", 22, 0)
        resultRow.calcResultText:SetPoint("RIGHT", resultRow.calcCard, "RIGHT", -12, 0)
        SetClippedText(resultRow.calcResultText, data.calculatorResultShown or data.calculatorResult)
        resultRow.calcResultHighlight:ClearAllPoints()
        resultRow.calcResultHighlight:SetPoint("TOPLEFT", resultRow.calcDivider, "TOPRIGHT", 1, 0)
        resultRow.calcResultHighlight:SetPoint("BOTTOMRIGHT", resultRow.calcCard, "BOTTOMRIGHT", -1, 1)
        resultRow.calcResultFlash:ClearAllPoints()
        resultRow.calcResultFlash:SetPoint("TOPLEFT", resultRow.calcResultHighlight, "TOPLEFT")
        resultRow.calcResultFlash:SetPoint("BOTTOMRIGHT", resultRow.calcResultHighlight, "BOTTOMRIGHT")
        resultRow.calcExpressionButton:ClearAllPoints()
        resultRow.calcExpressionButton:SetPoint("TOPLEFT", resultRow.calcCard, "TOPLEFT", 1, 0)
        resultRow.calcExpressionButton:SetPoint("BOTTOMRIGHT", resultRow.calcDivider, "BOTTOMLEFT", -1, 1)
        resultRow.calcExpressionButton:Show()

        resultRow.calcResultButton:ClearAllPoints()
        resultRow.calcResultButton:SetPoint("TOPLEFT", resultRow.calcDivider, "TOPRIGHT", 1, 0)
        resultRow.calcResultButton:SetPoint("BOTTOMRIGHT", resultRow.calcCard, "BOTTOMRIGHT", -1, 1)
        resultRow.calcResultButton:Show()

        self:SetCalculatorCopyHighlight(resultRow, Calculator._calculator.activeData == data and Calculator._calculator.activePart or nil)
        return true
    end

    return true
end
