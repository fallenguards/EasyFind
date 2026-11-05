local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Rows = ns.ResultRows

local sformat, unpack = ns.Utils.sformat, ns.Utils.unpack
local GetActionBarToggles, SetActionBarToggles = GetActionBarToggles, SetActionBarToggles
local GetActionBarPage = C_ActionBar and C_ActionBar.GetActionBarPage

-- Bars 2 to 8 in GetActionBarToggles order. Never written through the
-- setter: it runs Edit Mode's bar layout in our name (Rows.FlipBarToggle).
local BAR_TOGGLE_INDEX = {
    PROXY_SHOW_ACTIONBAR_2 = 1, PROXY_SHOW_ACTIONBAR_3 = 2, PROXY_SHOW_ACTIONBAR_4 = 3,
    PROXY_SHOW_ACTIONBAR_5 = 4, PROXY_SHOW_ACTIONBAR_6 = 5, PROXY_SHOW_ACTIONBAR_7 = 6,
    PROXY_SHOW_ACTIONBAR_8 = 7,
}

-- Settings of addon windows (API.RegisterSettingsIndex controls): read and
-- written through their own functions under a made-up variable name, so
-- every settings row widget serves them unchanged.
local customSettings = {}
function Rows:RegisterCustomSetting(variable, control) customSettings[variable] = control end

local function ReadSettingVariable(variable)
    local custom = customSettings[variable]
    if custom then
        local ok, value = pcall(custom.get)
        if ok then return value end
        return nil
    end
    if Settings and Settings.GetSetting then
        local sok, settObj = pcall(Settings.GetSetting, variable)
        if sok and settObj and settObj.GetValue then
            local vok, value = pcall(settObj.GetValue, settObj)
            if vok then return value end
        end
    end
    if GetCVar then
        local ok, value = pcall(GetCVar, variable)
        if ok then return value end
    end
end

local function WriteSettingVariable(variable, value)
    if BAR_TOGGLE_INDEX[variable] then return false end
    local custom = customSettings[variable]
    if custom then return (pcall(custom.set, value)) end
    -- Prefer the per-setting object: GetSetting returns nil for variables
    -- the Settings panel doesn't know about, so a successful SetValue here
    -- means the write actually went somewhere. Settings.SetValue (static)
    -- is a silent no-op for unregistered variables, so we skip it.
    if Settings and Settings.GetSetting then
        local sok, settObj = pcall(Settings.GetSetting, variable)
        if sok and settObj and settObj.SetValue then
            -- Coerce to the setting's declared variable type before
            -- writing. Type mismatches (e.g. passing "1" to a number
            -- setting) make Setting:SetValue silently no-op, which
            -- looks like a flicker on our row: pcall succeeds but
            -- the underlying value never changes.
            local writeValue = value
            if settObj.GetVariableType then
                local tok, vtype = pcall(settObj.GetVariableType, settObj)
                if tok and type(vtype) == "string" then
                    if vtype == "number" then
                        writeValue = tonumber(value) or value
                    elseif vtype == "string" then
                        writeValue = tostring(value)
                    elseif vtype == "boolean" then
                        if type(value) == "boolean" then
                            writeValue = value
                        elseif value == "1" or value == 1 or value == "true" then
                            writeValue = true
                        elseif value == "0" or value == 0 or value == "false" then
                            writeValue = false
                        end
                    end
                end
            end
            if pcall(settObj.SetValue, settObj, writeValue) then
                -- Settings flagged with CommitFlag.Apply stage to
                -- pendingValue (graphics, resolution, etc.) and need
                -- the user to commit. Tell BlizzOptionsSearch so the
                -- floating Apply/Revert bar can surface the change.
                if ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.NotePendingApply then
                    ns.BlizzOptionsSearch:NotePendingApply(variable)
                end
                -- Verify: SetValue can succeed on the call but reject
                -- the value internally. Read back to confirm it took.
                if settObj.GetValue then
                    local rok, raw = pcall(settObj.GetValue, settObj)
                    if rok and (raw == writeValue or tostring(raw) == tostring(writeValue)) then
                        return true
                    end
                else
                    return true
                end
            end
        end
    end
    -- CVar fallback for raw CVars not registered with the Settings panel.
    -- Booleans need explicit "1"/"0": tostring(true) gives "true", which
    -- a CVar slot would store literally and break the next read.
    if SetCVar then
        local cvarVal
        if type(value) == "boolean" then
            cvarVal = value and "1" or "0"
        else
            cvarVal = tostring(value)
        end
        if pcall(SetCVar, variable, cvarVal) then return true end
    end
    return false
end

function Rows:ReadSettingVariable(variable)
    return ReadSettingVariable(variable)
end

function Rows:WriteSettingVariable(variable, value)
    return WriteSettingVariable(variable, value)
end

-- Refresh rows in place (checkbox states re-read) and hand focus back
-- to the editbox, without closing the search panel.
local function RefreshResultsKeepFocus()
    Search:RefreshResults()
    if Search:GetSearchFrame() and Search:GetSearchFrame().editBox
       and not (Search:GetNavFrame() and Search:GetNavFrame():IsKeyboardEnabled()) then
        Search:GetSearchFrame().editBox.blockFocus = nil
        Search:GetSearchFrame().editBox:SetFocus()
    end
end

-- The value just set, shown at once (some GetValue lags a frame); expires
-- so an outside change still shows.
local function ShowSettingState(results, var, isOn)
    if isOn == nil then return end
    local token = { var = var, isOn = isOn }
    results._settingOptimistic = token
    ns.Utils.SafeAfter(0.6, function()
        if results._settingOptimistic == token then results._settingOptimistic = nil end
    end)
end

-- Toggle a boolean setting in place (clicked from a result row).
-- Tries the Settings API first (handles non-CVar settings like action
-- bar visibility), falls back to GetCVar/SetCVar.
function Results:ToggleSettingCheckbox(data)
    if not data or not data.settingVariable then return end
    local var = data.settingVariable
    local curVal = Rows:ReadSettingVariable(var)
    local newOn
    if type(curVal) == "boolean" then
        Rows:WriteSettingVariable(var, not curVal)
        newOn = not curVal
    elseif curVal == "1" or curVal == "0" then
        Rows:WriteSettingVariable(var, curVal == "1" and "0" or "1")
        newOn = curVal == "0"
    elseif curVal == "true" or curVal == "false" then
        Rows:WriteSettingVariable(var, curVal == "true" and "false" or "true")
        newOn = curVal == "false"
    elseif curVal == 1 or curVal == 0 then
        Rows:WriteSettingVariable(var, curVal == 1 and 0 or 1)
        newOn = curVal == 0
    end
    ShowSettingState(self, var, newOn)
    RefreshResultsKeepFocus()
end

function Rows.IsBarToggle(variable)
    return BAR_TOGGLE_INDEX[variable] ~= nil
end

-- The row's secure macro: a page change and back, so the game redraws the
-- bars in its own call; off in combat, where the press flips nothing.
function Rows.BarRedrawMacro()
    local page = GetActionBarPage()
    return sformat("/changeactionbar [nocombat] %d\n/changeactionbar [nocombat] %d", page == 1 and 2 or 1, page)
end

-- The press: the bar flipped in the game's mask; returns its new state.
function Rows.FlipBarToggle(variable)
    local index = BAR_TOGGLE_INDEX[variable]
    local toggles = { GetActionBarToggles() }
    if not index or index > #toggles then return nil end
    toggles[index] = not toggles[index]
    SetActionBarToggles(unpack(toggles))
    return toggles[index]
end

-- After the secure redraw: the row shows the state it just set.
function Results:ShowBarToggle(variable, isOn)
    ShowSettingState(self, variable, isOn)
    RefreshResultsKeepFocus()
end

local function ActivateSettingResult(data, openMenuHeld)
    if not data then return false end
    -- Merged keybind toggle: a plain click performs the action itself; Alt+click
    -- falls through to the Settings > Keybindings deep link. A customToggle has
    -- no Keybindings row behind it (EasyFind-owned action, e.g. hide chat), so
    -- left-click is its only action -- perform it on Alt too rather than
    -- deep-linking to a panel that can't show it.
    if data.settingType == "keybind" and data.bindingAction
       and (not openMenuHeld or data.customToggle)
       and ns.BlizzOptionsSearch
       and ns.BlizzOptionsSearch:PerformBinding(data.bindingAction) then
        RefreshResultsKeepFocus()
        return true
    end
    -- A button of an addon's window: pressed where it stands.
    if data.settingPress and not openMenuHeld then
        xpcall(data.settingPress, ns.Utils.ErrorHandler)
        RefreshResultsKeepFocus()
        return true
    end
    if not data.settingVariable then return false end
    local stype = data.settingType
    if (stype == "checkbox" or stype == "checkboxSlider" or stype == "checkboxDropdown")
       and not openMenuHeld and not BAR_TOGGLE_INDEX[data.settingVariable] then
        -- Plain click toggles inline. Alt+click falls through to open
        -- the in-game Settings panel for the same variable. For the
        -- composite types, the cb variable lives at data.settingVariable
        -- so the existing toggle path Just Works.
        Results:ToggleSettingCheckbox(data)
        return true
    end
    -- Sliders, keybinds, dropdowns and bar rows with no secure click (a
    -- code-driven Enter) open Settings there through SelectResult.
    return false
end

function Rows:ActivateSettingResult(data, openMenuHeld)
    return ActivateSettingResult(data, openMenuHeld)
end
