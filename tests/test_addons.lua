-- Addons on and off (2026-11-19): each installed addon a row with a
-- checkbox, switched for this character and in force at the next reload,
-- and a Reload row to apply.
local H = require("Harness")

local function World()
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.L.ADDONS_AFTER_RELOAD, ns.L.ADDONS_RELOAD_SUB = "changes at the next reload", "Applies addons switched on or off"
    ns.EXTENSIONS_ICON_TEX = "apps"
    ns.Utils.StripMarkup = ns.Utils.StripMarkup or function(s) return s end
    local t = { saved = 0, on = { EasyFind = true, Questie = true, Details = false }, with = {}, env = env }
    env.CANCEL = "Cancel"
    env.UnitGUID = function() return "Player-1-ME" end
    env.RELOADUI = "Reload UI"
    local list = { { "EasyFind", "|cff00ff00EasyFind|r", "INSECURE" }, { "Questie", "Questie", "INSECURE" },
                   { "Details", "", "INSECURE" }, { "Blizzard_Calendar", "Calendar", "SECURE" } }
    env.C_AddOns = {
        GetNumAddOns = function() return #list end,
        GetAddOnInfo = function(i) return list[i][1], list[i][2], "", true, nil, list[i][3] end,
        GetAddOnEnableState = function(name, who) t.with[name] = who return t.on[name] and 2 or 0 end,
        EnableAddOn = function(name, who) t.on[name], t.with[name] = true, who end,
        DisableAddOn = function(name, who) t.on[name], t.with[name] = false, who end,
        SaveAddOns = function() t.saved = t.saved + 1 end,
        GetAddOnMetadata = function(name, field) return name == "Questie" and field == "IconTexture" and "questie-icon" or nil end,
    }
    local custom = {}
    ns.ResultRows.RegisterCustomSetting = function(_, variable, control) custom[variable] = control end
    t.custom = custom
    ns.Database.uiSearchData = {}
    ns.Database.RemoveEntriesByCategory = function(category)
        local data = ns.Database.uiSearchData
        for i = #data, 1, -1 do if data[i].category == category then table.remove(data, i) end end
    end
    H.loadModule("Database/AddOns.lua", env, ns)
    ns.Database:PopulateDynamicAddOns()
    local rows = {}
    for _, row in ipairs(ns.Database.uiSearchData) do rows[row.name] = row end
    return ns, t, rows
end

local tests = {}

function tests.eachInstalledAddon_aCheckboxRow_theGamesOwnLeftOut()
    local ns, _, rows = World()
    H.assertEq(#ns.Database.uiSearchData, 4, "three addons and the Reload row")
    H.assertNotNil(rows.EasyFind, "its title without the color codes")
    H.assertEq(rows.EasyFind.settingType, "checkbox")
    H.assertEq(rows.EasyFind.settingVariable, "addon:EasyFind")
    H.assertEq(rows.EasyFind.category, "AddOn")
    H.assertNotNil(rows.Details, "no title: its folder's name")
    H.assertNil(rows.Calendar, "the game's own addons are not the player's to switch")
    H.assertEq(rows.Questie.glyph.tex, "questie-icon", "its own icon where it has one")
end

function tests.theCheckbox_switchesItForThisCharacter_andSavesTheList()
    local ns, t, rows = World()
    local control = t.custom["addon:Questie"]
    H.assertTrue(control.get(), "on")
    control.set(false)
    H.assertFalse(t.on.Questie)
    H.assertEq(t.with.Questie, "Player-1-ME", "for this character, as the game's own list does")
    H.assertEq(t.saved, 1)
    H.assertFalse(control.get())
    H.assertEq(ns.AddOns.Line(rows.Questie), "Questie, changes at the next reload")
    control.set(true)
    H.assertEq(ns.AddOns.Line(rows.Questie), "Questie", "switched back: nothing is owed")
end

function tests.aRepopulate_keepsWhatTheSessionStartedWith()
    local ns, t = World()
    t.custom["addon:Details"].set(true)
    ns.Database:PopulateDynamicAddOns()
    local row
    for _, r in ipairs(ns.Database.uiSearchData) do if r.addonName == "Details" then row = r end end
    H.assertEq(ns.AddOns.Line(row), "Details, changes at the next reload")
end

function tests.theReloadRow_appliesThem()
    local _, _, rows = World()
    local reload = rows["Reload UI"]
    H.assertEq(reload.slashCommand, "/reload")
    H.assertEq(reload.searchCommandDesc, "Applies addons switched on or off")
end

-- A switched addon stages like a game setting under Apply ("isn't popping
-- up the reload and cancel button like our usual apply and cancel buttons
-- do", 2026-11-20): its row grows the strip, Cancel puts it back, Reload UI
-- reloads.
function tests.aSwitchedAddon_stagesWithCancelAndReload()
    local ns, t, rows = World()
    local control = t.custom["addon:Questie"]
    H.assertFalse(control.pending(), "as the session found it: no strip")
    control.set(false)
    H.assertTrue(control.pending(), "switched: Cancel and Reload UI under its row")
    H.assertEq(control.applyText, "Reload UI")
    H.assertEq(control.revertText, "Cancel")
    control.revert()
    H.assertTrue(t.on.Questie, "Cancel puts it back as the session found it")
    H.assertFalse(control.pending())
    H.assertEq(ns.AddOns.Line(rows.Questie), "Questie")
    local reloads = 0
    t.env.ReloadUI = function() reloads = reloads + 1 end
    ns.Database:PopulateDynamicAddOns()
    t.custom["addon:Details"].set(true)
    t.custom["addon:Details"].apply()
    H.assertEq(reloads, 1, "Reload UI reloads")
end

-- The rows ask the control whether its strip shows.
function tests.theRowsStrip_followsTheControl()
    local ns, t, rows = World()
    ns.ResultRows.CustomSetting = function(_, variable) return t.custom[variable] end
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Render/Layout.lua", "rb"))
    local layout = f:read("a")
    f:close()
    local s = assert(layout:find("\nfunction Render.GetResultPendingApply(data)", 1, true))
    local _, e = layout:find("\nend\r?\n", s)
    local Render = {}
    assert(load("local Render, ns = ...\n" .. layout:sub(s, e), "=Layout.lua", "t", t.env))(Render, ns)
    H.assertFalse(Render.GetResultPendingApply(rows.Questie))
    t.custom["addon:Questie"].set(false)
    H.assertTrue(Render.GetResultPendingApply(rows.Questie), "switched: the strip shows")
    H.assertFalse(Render.GetResultPendingApply(rows.EasyFind), "its neighbours' do not")
    local widgets = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Rows/SettingWidgets.lua", "rb"))
    local text = widgets:read("a")
    widgets:close()
    H.assertTrue(text:find("custom.revertText", 1, true) ~= nil and text:find("custom.apply()", 1, true) ~= nil,
        "the strip's buttons wear the control's labels and run its apply")
end

local pass, fail, failures = H.runSuite("AddOns", tests)
return { pass = pass, fail = fail, failures = failures }
