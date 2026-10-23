-- EasyFind's own setting rows in the search bar change their setting in
-- place (Apps/Options/OptionsPanel.lua, Apps/Settings/BlizzSearch.lua): every
-- flyout selector is a dropdown there, EasyFind's binds are key buttons, and a
-- hit with nothing to change (a heading, a badge) is no row. The Font row had
-- no dropdown, and "EXP", "EasyFind" and "Map" were rows of nothing.
local H = require("Harness")

local function source(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function slice(src, from, to)
    local s = assert(src:find(from, 1, true), from .. " not found")
    local e = assert(src:find(to, s + #from, true), to .. " not found")
    return src:sub(s, e - 1)
end

local tests = {}

-- Any frame call answers: what the selector rows draw is not under test.
local function Stub()
    return setmetatable({}, { __index = function(_, k)
        if k == "CreateFontString" or k == "CreateTexture" then return function() return Stub() end end
        if k == "GetUnboundedStringWidth" or k == "GetStringWidth" then return function() return 10 end end
        if k:sub(1, 1) == "_" then return nil end   -- fields, not methods
        return function() end
    end })
end

function tests.everySelectorIsADropdown()
    local env = H.newEnv()
    env.CreateFrame = function() return Stub() end
    env.PaintRoundedFill, env.HideRoundedFrameBorder = function() end, function() end
    env.ns = { CreateRoundedRectBorder = function() end, SetRoundedRectBarHeight = function() end }
    env.mmax, env.mfloor = math.max, math.floor
    local chunk = slice(source("Apps/Options/OptionsPanel.lua"), "local function AddFlyoutOptions",
        "\nlocal function ") .. "\nreturn AddFlyoutOptions"
    local AddFlyoutOptions = assert(load(chunk, "=OptionsPanel.lua AddFlyoutOptions", "t", env))()
    local shown = "Friz Quadrata"
    local row = {}
    local btn = { _efText = { GetText = function() return shown end }, GetParent = function() return row end }
    local flyout = Stub()
    rawset(flyout, "GetParent", function() return btn end)
    local picked
    AddFlyoutOptions(flyout, { "Default", "Friz" }, 100, function(name) picked = name end,
        function(name) return name == "Friz" and "Friz Quadrata" or name end)
    local control = row._efControl
    H.assertEq(control and control.kind, "choice")
    H.assertEq(control.choices[2].label, "Friz Quadrata")
    H.assertEq(control.get(), "Friz", "the value its button shows")
    control.set("Default")
    H.assertEq(picked, "Default", "chosen the way a click chooses")
end

function tests.hitsWithNothingToChangeAreNoRows()
    local function target(kind, control)
        return { _efControl = control, GetObjectType = function() return kind end, GetScript = function() end }
    end
    local optionsFrame = {
        TabName = function() return "General & binds" end,
        SettingsIndex = function()
            return {
                { label = "Font", tab = 1, target = target("Frame", { kind = "choice" }) },
                { label = "Toggle search bar:", tab = 1, target = target("Frame", { kind = "keybind", action = "X" }) },
                { label = "EasyFind", tab = 1, target = target("Frame") },
                { label = "Map", tab = 1, target = target("Frame") },
            }
        end,
    }
    local Options = { Initialize = function() end }
    local env = setmetatable({ Options = Options, optionsFrame = optionsFrame }, { __index = _G })
    local chunk = slice(source("Apps/Options/OptionsPanel.lua"), "local function ControlOf",
        "\nfunction Options:ExtensionPageFrames")
    assert(load(chunk, "=OptionsPanel.lua SettingsIndexRows", "t", env))()
    local names = {}
    for i, r in ipairs(Options:SettingsIndexRows()) do names[i] = r.name end
    H.assertEq(table.concat(names, ", "), "Font, Toggle search bar", "a label's colon dropped too")
end

function tests.easyFindsBindsAreKeyButtons()
    local env = setmetatable({ ns = { ResultRows = { RegisterCustomSetting = function() end } },
        AddOptionLabelKeywords = function() end }, { __index = _G })
    local chunk = slice(source("Apps/Settings/BlizzSearch.lua"), "local FEED_KINDS", "\nlocal function PullFeed")
        .. "\nreturn FeedControl"
    local FeedControl = assert(load(chunk, "=BlizzSearch.lua FeedControl", "t", env))()
    local e = {}
    FeedControl(e, { kind = "keybind", action = "EASYFIND_TOGGLE_FOCUS" }, "EasyFind")
    H.assertEq(e.settingType, "keybind")
    H.assertEq(e.bindingAction, "EASYFIND_TOGGLE_FOCUS")
    H.assertTrue(e.accountKeybind, "read and set through EasyFind")
end

local pass, fail, failures = H.runSuite("OptionsSettingControls", tests)
return { pass = pass, fail = fail, failures = failures }
