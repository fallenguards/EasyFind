-- Settings that wait for Apply (graphics, display mode, window size) changed
-- from a result row (Apps/Settings/BlizzSearch.lua, Search/Results): the row's
-- Apply and Reset strip shows as the change stages, and Apply does what the
-- game's own Apply does after its writes (SettingsPanel FinalizeCommit):
-- UpdateWindow for display mode, window size and monitor, RestartGx for the
-- GxRestart settings. Era, 2026-11-04: the strip came only after searching
-- again, and display mode stayed as it was after Apply. A Revertable setting
-- then asks "keep these settings?" in the game's own dialog, reverted when
-- not kept within 8 s (Blizzard_Dialogs.lua GAME_SETTINGS_TIMED_CONFIRMATION).
local H = require("Harness")

local function Read(rel)
    local fh = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local text = fh:read("*a")
    fh:close()
    return text
end

local Flag = { Apply = 1, GxRestart = 2, UpdateWindow = 4, Revertable = 8 }

-- The client's setting object (Blizzard_Setting.lua SettingMixin): an Apply
-- setting's SetValue stages pendingValue, SetValue(v, true) writes it.
local function Setting(variable, value, flags)
    local s = { variable = variable, value = value, flags = flags }
    function s:GetVariable() return self.variable end
    function s:GetValueDerived() return self.value end
    function s:HasCommitFlag(f) return self.flags & f ~= 0 end
    function s:GetValue()
        if self.pendingValue ~= nil then return self.pendingValue end
        return self.value
    end
    function s:SetValue(v, immediate)
        if immediate or not self:HasCommitFlag(Flag.Apply) then
            self.pendingValue, self.value = nil, v
        elseif v == self.value then
            self.pendingValue = nil
        else
            self.pendingValue = v
        end
    end
    function s:Revert() self.pendingValue = nil end
    return s
end

local function Load()
    local env = H.newEnv()
    env._G = env
    local settings = {
        PROXY_DISPLAY_MODE = Setting("PROXY_DISPLAY_MODE", false,
            Flag.Apply | Flag.UpdateWindow | Flag.Revertable),
        PROXY_VSYNC = Setting("PROXY_VSYNC", false, Flag.Apply | Flag.GxRestart),
        PROXY_MSAA_MODE = Setting("PROXY_MSAA_MODE", 1, Flag.Apply | Flag.GxRestart),
        PROXY_VIEW_DISTANCE = Setting("PROXY_VIEW_DISTANCE", 3, Flag.Apply),
    }
    env.Settings = {
        GetSetting = function(v) return settings[v] end,
        CommitFlag = Flag,
    }
    local calls = { gx = 0, window = 0, redraw = 0 }
    env.RestartGx = function() calls.gx = calls.gx + 1 end
    env.UpdateWindow = function() calls.window = calls.window + 1 end
    env.mouseDown = false
    env.IsMouseButtonDown = function() return env.mouseDown end
    -- The client's dialogs and timers, recorded.
    env.StaticPopupDialogs = {}
    env.SETTINGS_CONFIRM_TIMEOUT_BUTTON, env.SETTINGS_CANCEL_TIMEOUT_BUTTON = "Keep Settings", "Revert"
    env.SETTINGS_TIMED_CONFIRMATION = "Keep these settings? Reverting in %d seconds."
    local popup = {}
    env.StaticPopup_Show = function(which, _, _, data) popup.shown, popup.data = which, data end
    env.StaticPopup_Hide = function(which) if popup.shown == which then popup.shown = nil end end
    env.C_Timer = env.C_Timer or {}
    env.C_Timer.NewTimer = function(seconds, fn)
        local t = { seconds = seconds, fn = fn }
        function t:Cancel() self.cancelled = true end
        popup.timer = t
        return t
    end
    calls.popup = popup
    local ns = H.newNs(env)
    local timers = {}
    ns.Utils.SafeAfter = function(_, fn) timers[#timers + 1] = fn end
    local function NextFrame()
        local due = timers
        timers = {}
        for _, fn in ipairs(due) do fn() end
    end
    ns.Database.uiSearchData = {}
    env.EasyFind._ns = ns
    H.loadModule("Search/Openers.lua", env, ns)
    H.loadModule("Apps/Settings/BlizzSearch.lua", env, ns)
    ns.Search.RefreshResults = function() calls.redraw = calls.redraw + 1 end
    local Blizz = ns.BlizzOptionsSearch
    -- A change made on a row: the setting staged, then EasyFind told.
    local function Stage(variable, value)
        settings[variable]:SetValue(value)
        Blizz:NotePendingApply(variable)
    end
    return Blizz, settings, calls, Stage, NextFrame, env, ns
end

local tests = {}

function tests.applyingDisplayMode_switchesTheWindow()
    local Blizz, settings, calls, Stage = Load()
    Stage("PROXY_DISPLAY_MODE", true)
    Blizz:ApplyVariable("PROXY_DISPLAY_MODE")
    H.assertEq(settings.PROXY_DISPLAY_MODE.value, true, "written")
    H.assertNil(settings.PROXY_DISPLAY_MODE.pendingValue)
    H.assertEq(calls.window, 1, "the window takes the new mode, as the game's Apply does it")
    H.assertEq(calls.gx, 0, "no graphics restart for it")
end

function tests.graphicsRestartSettings_restartOnceForTheBatch()
    local Blizz, settings, calls, Stage = Load()
    Stage("PROXY_VSYNC", true)
    Stage("PROXY_MSAA_MODE", 2)
    Blizz:ApplyPendingChanges()
    H.assertEq(settings.PROXY_VSYNC.value, true)
    H.assertEq(settings.PROXY_MSAA_MODE.value, 2)
    H.assertEq(calls.gx, 1, "one restart after both writes")
    Stage("PROXY_VSYNC", false)
    Stage("PROXY_MSAA_MODE", 1)
    Blizz:ApplyVariable("PROXY_VSYNC", "PROXY_MSAA_MODE")
    H.assertEq(calls.gx, 2, "a row's Apply for two variables restarts once too")
end

function tests.aPlainApplySetting_restartsNothing()
    local Blizz, settings, calls, Stage = Load()
    Stage("PROXY_VIEW_DISTANCE", 7)
    Blizz:ApplyVariable("PROXY_VIEW_DISTANCE")
    H.assertEq(settings.PROXY_VIEW_DISTANCE.value, 7)
    H.assertEq(calls.gx + calls.window, 0)
end

-- The strip follows the staged value, whatever wrote it (a slider's step
-- arrows redrew nothing).
function tests.stagingOrClearing_redrawsTheRowsOnce()
    local _, _, calls, Stage, NextFrame, env = Load()
    Stage("PROXY_VIEW_DISTANCE", 5)
    NextFrame()
    H.assertEq(calls.redraw, 1, "staged: the strip appears")
    Stage("PROXY_VIEW_DISTANCE", 6)
    NextFrame()
    H.assertEq(calls.redraw, 1, "still staged: nothing new to draw")
    env.mouseDown = true
    Stage("PROXY_VIEW_DISTANCE", 3)
    NextFrame()
    H.assertEq(calls.redraw, 1, "mid-drag: the release redraws")
    env.mouseDown = false
    Stage("PROXY_VIEW_DISTANCE", 4)
    Stage("PROXY_VIEW_DISTANCE", 3)
    NextFrame()
    H.assertEq(calls.redraw, 2, "staged and cleared again in one frame: one redraw")
end

function tests.aDropdownBesideACheckbox_showsAndAppliesItsOwnStrip()
    local Blizz, settings, calls, Stage, _, env, ns = Load()
    local layout = Read("Search/Results/Render/Layout.lua")
    local s = assert(layout:find("\nfunction Render.GetResultPendingApply(data)", 1, true))
    local _, e = layout:find("\nend\r?\n", s)
    local Render = {}
    assert(load("local Render, ns = ...\n" .. layout:sub(s, e), "=Layout.lua", "t", env))(Render, ns)
    local row = { settingVariable = "PROXY_VSYNC_ON", dropdownVariable = "PROXY_MSAA_MODE" }
    Stage("PROXY_MSAA_MODE", 4)
    H.assertTrue(Render.GetResultPendingApply(row), "the dropdown's staged value shows the strip")
    local widgets = Read("Search/Results/Rows/SettingWidgets.lua")
    H.assertTrue(widgets:find("local dropdown = d.dropdownVariable", 1, true) ~= nil, "Apply and Reset take the dropdown's variable")
    Blizz:ApplyVariable(row.settingVariable, row.dropdownVariable)
    H.assertEq(settings.PROXY_MSAA_MODE.value, 4, "applied")
    H.assertEq(calls.gx, 1)
end

local KEEP = "EASYFIND_SETTINGS_TIMED_CONFIRMATION"

function tests.displayMode_asksToKeepIt_inTheGamesOwnDialog()
    local Blizz, _, calls, Stage, _, env = Load()
    Stage("PROXY_DISPLAY_MODE", true)
    Blizz:ApplyVariable("PROXY_DISPLAY_MODE")
    H.assertEq(calls.popup.shown, KEEP, "asked")
    H.assertEq(calls.popup.data, 8, "for the game's 8 seconds")
    H.assertEq(calls.popup.timer.seconds, 8)
    local dialog = env.StaticPopupDialogs[KEEP]
    H.assertEq(dialog.button1, env.SETTINGS_CONFIRM_TIMEOUT_BUTTON, "the game's Keep button")
    H.assertEq(dialog.button2, env.SETTINGS_CANCEL_TIMEOUT_BUTTON, "and its Revert")
    H.assertTrue(dialog.whileDead and dialog.fullScreenCover, "shown as the game's is")
end

function tests.notKeptInTime_putsTheOldModeBack()
    local Blizz, settings, calls, Stage = Load()
    Stage("PROXY_DISPLAY_MODE", true)
    Blizz:ApplyVariable("PROXY_DISPLAY_MODE")
    calls.popup.timer.fn()
    H.assertEq(settings.PROXY_DISPLAY_MODE.value, false, "reverted")
    H.assertEq(calls.window, 2, "and the window follows it back")
    H.assertNil(calls.popup.shown, "the dialog goes")
end

function tests.keepAndRevert_buttons()
    local Blizz, settings, calls, Stage, _, env = Load()
    local dialog
    Stage("PROXY_DISPLAY_MODE", true)
    Blizz:ApplyVariable("PROXY_DISPLAY_MODE")
    dialog = env.StaticPopupDialogs[KEEP]
    dialog.OnAccept()
    H.assertTrue(calls.popup.timer.cancelled, "kept: no revert later")
    H.assertEq(settings.PROXY_DISPLAY_MODE.value, true)
    Stage("PROXY_DISPLAY_MODE", false)
    Blizz:ApplyVariable("PROXY_DISPLAY_MODE")
    dialog.OnCancel()
    H.assertEq(settings.PROXY_DISPLAY_MODE.value, true, "Revert puts back what was kept")
end

function tests.aSettingTheGameDoesNotAskAbout_isNotAsked()
    local Blizz, _, calls, Stage = Load()
    Stage("PROXY_VSYNC", true)
    Blizz:ApplyVariable("PROXY_VSYNC")
    H.assertNil(calls.popup.shown)
end

local pass, fail, failures = H.runSuite("SettingsApply", tests)
return { pass = pass, fail = fail, failures = failures }
