-- A raised menu stays under the hint tooltip (Shared/Utils.lua RaiseMenu),
-- 2026-10-26: a flyout's Raise put it over the 9999 hint, and the GPS
-- window's settings rows showed their hints behind it.
local H = require("Harness")

local function Source()
    local f = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function Load()
    local src = Source()
    local s = assert(src:find("Utils.HINT_LEVEL = 9999", 1, true))
    local fs = assert(src:find("function Utils.RaiseMenu(frame)", s, true))
    local _, e = src:find("\nend\r?\n", fs)
    local env = setmetatable({ Utils = {} }, { __index = _G })
    assert(load(src:sub(s, e), "=Utils.lua RaiseMenu", "t", env))()
    return env.Utils
end

-- Raise as the client does: above every frame in the strata, to its cap.
local function Frame(level)
    local f = { level = level }
    function f:Raise() self.level = 10000 end
    function f:GetFrameLevel() return self.level end
    function f:SetFrameLevel(l) self.level = l end
    return f
end

local tests = {}

function tests.aRaisedMenuStaysUnderTheHint()
    local Utils = Load()
    local flyout = Frame(9020)
    Utils.RaiseMenu(flyout)
    H.assertTrue(flyout.level < Utils.HINT_LEVEL, "under the hint: " .. flyout.level)
    H.assertTrue(flyout.level > 9900, "still over every menu below it")
end

function tests.everyMenuRaiseGoesThroughIt()
    local src = Source()
    H.assertTrue(src:find("child:Raise()", 1, true) == nil, "the flyout")
    H.assertTrue(src:find("if self.Raise then self:Raise() end", 1, true) == nil, "the keyboard menu")
    H.assertTrue(src:find("tip:SetFrameLevel(Utils.HINT_LEVEL)", 1, true) ~= nil, "the hint at that level")
end

local pass, fail, failures = H.runSuite("MenuHintLevel", tests)
return { pass = pass, fail = fail, failures = failures }
