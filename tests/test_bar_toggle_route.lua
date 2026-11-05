-- Action bar rows (Search/Results/Rows/Settings.lua BAR_TOGGLE_INDEX): the
-- game's setter runs Edit Mode's bar layout in its caller's name, and a row
-- that wrote "Show Action Bar 3" left MultiBarBottomLeft.snappedToFrame
-- tainted by EasyFind, so Edit Mode was refused ClearTarget for the session
-- (bartaint probe, Forever, 2026-11-04). A row's press flips the bar in the
-- game's mask and its secure macro pages away and back, so the game's own
-- page handler redraws the bars (/efd bartaint api: PASS, no taint).
local H = require("Harness")

local function Load(opts)
    opts = opts or {}
    local env = H.newEnv()
    local mask = { true, false, true, false, false, false, false }
    local sets, written = {}, {}
    env.GetActionBarToggles = function() return table.unpack(mask) end
    env.SetActionBarToggles = function(...)
        sets[#sets + 1] = { ... }
        mask = { ... }
    end
    env.C_ActionBar = { GetActionBarPage = function() return opts.page or 1 end }
    env.InCombatLockdown = function() return opts.combat == true end
    env.Settings = { GetSetting = function(variable)
        return { SetValue = function() written[#written + 1] = variable return true end,
            GetValue = function() return nil end }
    end }
    local ns = H.newNs(env)
    local toggled = {}
    H.loadModule("Search/Results/Rows/Settings.lua", env, ns)
    ns.Results.ToggleSettingCheckbox = function(_, data) toggled[#toggled + 1] = data.settingVariable end
    ns.ResultIcons, ns.ResultHandlers = {}, {}
    H.loadModule("Search/Results/SecureAttributes.lua", env, ns)
    return ns, { sets = sets, written = written, toggled = toggled, mask = function() return mask end }
end

local function Row()
    local attrs = {}
    return { SetAttribute = function(_, k, v) attrs[k] = v end }, attrs
end

local tests = {}

function tests.barRows_neverWriteTheSettingFromOurCode()
    local ns, seen = Load()
    for bar = 2, 8 do
        local variable = "PROXY_SHOW_ACTIONBAR_" .. bar
        H.assertTrue(ns.ResultRows.IsBarToggle(variable))
        H.assertFalse(ns.ResultRows:WriteSettingVariable(variable, true), "bar " .. bar .. ": writer refuses")
        H.assertFalse(ns.ResultRows:ActivateSettingResult({ settingType = "checkbox", settingVariable = variable }),
            "bar " .. bar .. ": a code-driven activation opens Settings")
    end
    H.assertEq(#seen.written, 0, "no SetValue on a bar setting")
    H.assertEq(#seen.toggled, 0, "no inline toggle from code")
end

function tests.press_flipsOnlyThatBarInTheGamesMask()
    local ns, seen = Load()
    H.assertEq(ns.ResultSecureAttributes.FlipBarAtPress({ settingVariable = "PROXY_SHOW_ACTIONBAR_3" }), true)
    H.assertEq(#seen.sets, 1)
    H.assertDeepEq(seen.mask(), { true, true, true, false, false, false, false })
    H.assertEq(ns.ResultSecureAttributes.FlipBarAtPress({ settingVariable = "PROXY_SHOW_ACTIONBAR_3" }), false)
    H.assertDeepEq(seen.mask(), { true, false, true, false, false, false, false }, "second press puts it back")
    H.assertEq(#seen.written, 0, "never the setter")
end

function tests.press_doesNothingInCombatOrForOtherRows()
    local ns, seen = Load({ combat = true })
    H.assertNil(ns.ResultSecureAttributes.FlipBarAtPress({ settingVariable = "PROXY_SHOW_ACTIONBAR_3" }))
    local calm = Load()
    H.assertNil(calm.ResultSecureAttributes.FlipBarAtPress({ settingVariable = "autoLootDefault" }))
    H.assertNil(calm.ResultSecureAttributes.FlipBarAtPress({ spellID = 133 }))
    H.assertEq(#seen.sets, 0)
end

function tests.secureMacro_pagesAwayAndBack()
    local ns = Load({ page = 1 })
    local row, attrs = Row()
    ns.ResultSecureAttributes.Apply(row, { settingVariable = "PROXY_SHOW_ACTIONBAR_4" })
    H.assertEq(attrs.type, "macro")
    H.assertEq(attrs.macrotext, "/changeactionbar [nocombat] 2\n/changeactionbar [nocombat] 1")
    local onPage3 = Load({ page = 3 })
    row, attrs = Row()
    onPage3.ResultSecureAttributes.Apply(row, { settingVariable = "PROXY_SHOW_ACTIONBAR_4" })
    H.assertEq(attrs.macrotext, "/changeactionbar [nocombat] 1\n/changeactionbar [nocombat] 3", "back to page 3")
end

function tests.otherCheckboxes_stillToggleInPlace()
    local ns, seen = Load()
    H.assertTrue(ns.ResultRows:ActivateSettingResult({ settingType = "checkbox", settingVariable = "autoLootDefault" }))
    H.assertEq(seen.toggled[1], "autoLootDefault")
end

local pass, fail, failures = H.runSuite("BarToggleRoute", tests)
return { pass = pass, fail = fail, failures = failures }
