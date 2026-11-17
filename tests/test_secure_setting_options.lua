-- Status Text (Search/Results/Rows/Settings.lua SECURE_OPTIONS): the game
-- answers a change by redrawing every health and power bar's text, and from
-- our code that redraw ran in EasyFind's name: 10 secret-compare errors on
-- the personal resource bar (Forever, 2026-11-17). Its values go through a
-- secure click whose macro sets the CVars with /console; our code never
-- writes the setting or its CVars.
local H = require("Harness")

local VAR = "PROXY_STATUS_TEXT"

local function Load(opts)
    opts = opts or {}
    local env = H.newEnv()
    local written, cvars, made = {}, {}, {}
    env.InCombatLockdown = function() return opts.combat == true end
    env.Settings = { GetSetting = function(variable)
        return { SetValue = function() written[#written + 1] = variable return true end,
            GetValue = function() return nil end }
    end }
    env.SetCVar = function(k) cvars[#cvars + 1] = k return true end
    env.CreateFrame = function(_, name, _, template)
        local f = H.newFrame()
        local strata = "MEDIUM"
        f.name, f.template = name, template
        f.RegisterForClicks = function() end
        f.SetFrameStrata = function(_, s) strata = s end
        f.GetFrameStrata = function() return strata end
        made[#made + 1] = f
        return f
    end
    local ns = H.newNs(env)
    ns.Utils.RegisterClickGuard = function() end
    H.loadModule("Search/Results/Rows/Settings.lua", env, ns)
    local function Pad()
        for _, f in ipairs(made) do if f.name == "EasyFindSettingOptionPad" then return f end end
    end
    return ns.ResultRows, { written = written, cvars = cvars, Pad = Pad, CreateFrame = env.CreateFrame }
end

local tests = {}

function tests.statusText_neverWrittenFromOurCode()
    local Rows, seen = Load()
    for value = 1, 4 do
        H.assertFalse(Rows:WriteSettingVariable(VAR, value), "value " .. value .. ": the writer refuses")
        H.assertFalse(Rows:WriteSettingVariable(VAR, tostring(value)), "as text too")
    end
    H.assertEq(#seen.written, 0, "no SetValue")
    H.assertEq(#seen.cvars, 0, "no SetCVar")
    H.assertTrue(Rows:WriteSettingVariable("autoLootDefault", true), "other settings still write")
end

function tests.eachValue_isTheGamesOwnCVarPair()
    local Rows = Load()
    local want = {
        "/console statusTextDisplay NUMERIC\n/console statusText 1",
        "/console statusTextDisplay PERCENT\n/console statusText 1",
        "/console statusTextDisplay BOTH\n/console statusText 1",
        "/console statusTextDisplay NONE\n/console statusText 0",
    }
    for value = 1, 4 do
        H.assertEq(Rows.SecureOptionMacro(VAR, value), want[value], "value " .. value)
        H.assertEq(Rows.SecureOptionMacro(VAR, tostring(value)), want[value], "as the picker's text value")
    end
    H.assertNil(Rows.SecureOptionMacro(VAR, 5))
    H.assertNil(Rows.SecureOptionMacro("autoLootDefault", 1))
end

function tests.thePad_clicksTheHoveredValue_andGoesWithIt()
    local Rows, seen = Load()
    local target = seen.CreateFrame("Button")
    local picked = 0
    H.assertTrue(Rows.ArmOptionPad(target, VAR, "2", function() picked = picked + 1 end))
    local pad = assert(seen.Pad(), "the pad")
    H.assertEq(pad.template, "SecureActionButtonTemplate")
    H.assertEq(pad:GetAttribute("type"), "macro")
    H.assertEq(pad:GetAttribute("macrotext"), "/console statusTextDisplay PERCENT\n/console statusText 1")
    H.assertTrue(pad:IsShown())
    pad:GetScript("PostClick")(pad, "LeftButton", false)
    H.assertEq(picked, 1, "the click's follow-up ran")
    H.assertEq(#seen.written + #seen.cvars, 0, "the macro wrote it, not our code")
    target:GetScript("OnHide")(target)
    H.assertFalse(pad:IsShown(), "its option gone: the pad goes")
    H.assertFalse(Rows.ArmOptionPad(target, "autoLootDefault", 1), "no pad for a plain setting")
end

function tests.inAFight_noPad()
    local Rows, seen = Load({ combat = true })
    H.assertFalse(Rows.ArmOptionPad(seen.CreateFrame("Button"), VAR, 1))
    H.assertNil(seen.Pad(), "nothing secure made or moved in a fight")
end

-- Every picker opened for a setting names it, so its rows can arm the pad.
function tests.everyPicker_namesItsSetting()
    local f = assert(io.open("Search/Results/Rows/SettingWidgets.lua", "rb"))
    local src = f:read("a")
    f:close()
    local calls = 0
    for args in src:gmatch("ToggleInlineSettingDropdown(%b())") do
        calls = calls + 1
        H.assertTrue(args:find(",%s*var%)$") ~= nil, "the picker gets the variable: " .. args:sub(1, 60))
    end
    H.assertTrue(calls > 0, "the picker found")
end

local pass, fail, failures = H.runSuite("SecureSettingOptions", tests)
return { pass = pass, fail = fail, failures = failures }
