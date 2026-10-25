-- Tests for key captures at combat start (Shared/Utils.lua ArmBindingCapture):
-- an armed capture stops as a fight starts, before lockdown, so a capture
-- button never keeps the keyboard (W/A/S/D) through a fight; the setup
-- wizard captures through the same helper.

local H = require("Harness")

local function Read(rel)
    local fh = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local text = fh:read("*a")
    fh:close()
    return text
end

-- The do-block that holds Arm/DisarmBindingCapture, run alone.
local function Load()
    local src = Read("Shared/Utils.lua")
    local s = assert(src:find("\ndo\nlocal armedCaptures = {}", 1, true) or src:find("\r\ndo\r\nlocal armedCaptures = {}", 1, true),
        "the capture block")
    local d = assert(src:find("\nfunction Utils.DisarmBindingCapture(frame)", s, true))
    local _, e = src:find("\nend\r?\nend\r?\n", d)
    local watch
    local env = setmetatable({
        CreateFrame = function()
            watch = { events = {} }
            function watch:Hide() end
            function watch:SetScript(_, fn) self.onEvent = fn end
            function watch:RegisterEvent(ev) self.events[ev] = true end
            function watch:UnregisterEvent(ev) self.events[ev] = nil end
            return watch
        end,
    }, { __index = _G })
    local Utils = {
        SafeCallMethod = function(obj, method, ...) return obj[method](obj, ...) end,
        CaptureKeybindCombo = function(key) return key end,
    }
    assert(load("local Utils = ...\n" .. src:sub(s, e), "=Utils capture", "t", env))(Utils)
    return Utils, function() return watch end
end

local function Button()
    local b = { scripts = {}, keyboard = false, wheel = false }
    function b:GetScript(k) return self.scripts[k] end
    function b:SetScript(k, fn) self.scripts[k] = fn end
    function b:IsMouseWheelEnabled() return self.wheel end
    function b:EnableMouseWheel(on) self.wheel = on end
    function b:EnableKeyboard(on) self.keyboard = on end
    return b
end

local tests = {}

function tests.aFightStopsAnArmedCapture()
    local Utils, watch = Load()
    local b, got = Button(), {}
    Utils.ArmBindingCapture(b, function(frame, combo)
        got[#got + 1] = combo
        Utils.DisarmBindingCapture(frame)
    end)
    H.assertTrue(b.keyboard, "armed: the button takes keys")
    H.assertTrue(watch().events.PLAYER_REGEN_DISABLED, "watching for a fight while armed")
    watch().onEvent(watch(), "PLAYER_REGEN_DISABLED")
    H.assertEq(got[1], "stop", "the capture ends as the fight starts")
    H.assertFalse(b.keyboard, "the keyboard is given back")
    H.assertNil(watch().events.PLAYER_REGEN_DISABLED, "no capture armed: no fight watch")
end

function tests.theWizardCapturesThroughTheSharedHelper()
    local src = Read("Apps/Onboarding/TutorialWizard.lua")
    H.assertTrue(src:find("Utils.ArmBindingCapture(", 1, true) ~= nil, "the wizard arms the shared capture")
    H.assertTrue(src:find("Utils.AttachEscClose(", 1, true) ~= nil, "Escape through the shared dispatch")
    H.assertNil(src:find("EnableKeyboard", 1, true), "the wizard takes no keyboard of its own")
end

local pass, fail, failures = H.runSuite("Capture combat", tests)
return { pass = pass, fail = fail, failures = failures }
