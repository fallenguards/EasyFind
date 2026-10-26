-- Ctrl+C over a target another window's scanner reports (the chat's
-- bubbles, Search/Results/RowCopy.lua) looks it up again on every press:
-- a bubble's speaker name copies the name, the rest the words. Reusing
-- the last target while the mouse stayed over it copied the words over
-- the name.
local H = require("Harness")

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/RowCopy.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local armed = {}
    local ns = {
        Search = { GetResultButtons = function() return {} end },
        Utils = {
            ArmClipboardBox = function(text) armed[#armed + 1] = text end,
            ClipboardBoxClient = function() return nil end,
            DisarmClipboardBox = function() end,
        },
        L = setmetatable({}, { __index = function(_, k) return k end }),
    }
    local env = setmetatable({
        IsControlKeyDown = function() return true end,
        IsShiftKeyDown = function() return false end,
        CreateFrame = function() return H.newFrame() end,
    }, { __index = _G })
    assert(load(src, "=RowCopy.lua", "t", env))("EasyFind", ns)
    return ns.RowCopy, armed
end

local function Target(text)
    return { _efCopyText = text, IsShown = function() return true end, IsMouseOver = function() return true end }
end

local tests = {}

function tests.aScannedTargetIsLookedUpAgainEachPress()
    local RowCopy, armed = Load()
    local bubble, name = Target("the words"), Target("Speaker-Realm")
    local under = bubble
    RowCopy:RegisterHoverScanner(function() return under end)
    RowCopy:ArmHovered()
    H.assertEq(armed[#armed], "the words")
    under = name   -- the mouse moved onto the name, still inside the bubble
    RowCopy:ArmHovered()
    H.assertEq(armed[#armed], "Speaker-Realm", "the name, not the bubble's words")
end

local pass, fail, failures = H.runSuite("RowCopyScanned", tests)
return { pass = pass, fail = fail, failures = failures }
