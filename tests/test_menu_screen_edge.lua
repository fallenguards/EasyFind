-- Menus keep a margin inside the screen (Utils.OpenFlyoutBeside and
-- OpenDropdownBelow, Shared/Utils.lua): their border art draws outside the
-- frame, and a flyout flush with the screen's bottom read as running off it
-- (the Notes Auto-show flyout, 2026-10-26).
local H = require("Harness")

local function Region(l, b, w, h)
    local r = { l = l, b = b, w = w, h = h }
    function r:GetLeft() return self.l end
    function r:GetRight() return self.l + self.w end
    function r:GetTop() return self.b + self.h end
    function r:GetBottom() return self.b end
    function r:GetWidth() return self.w end
    function r:GetHeight() return self.h end
    function r:GetEffectiveScale() return 1 end
    function r:ClearAllPoints() end
    function r:SetPoint(_, _, _, x, y) self.x, self.top = x, y end
    function r:SetClampedToScreen(on) self.clamped = on end
    function r:SetClampRectInsets(...) self.insets = { ... } end
    return r
end

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("Utils.MENU_EDGE = 8", 1, true))
    local d = assert(src:find("function Utils.OpenDropdownBelow(", s, true))
    local _, e = assert(src:find("\nend\r?\n", d))
    local Utils = {}
    local env = setmetatable({ Utils = Utils, UIParent = Region(0, 0, 1000, 700) }, { __index = _G })
    assert(load(src:sub(s, e), "=Utils.lua menu edge", "t", env))()
    return Utils
end

local tests = {}

function tests.aFlyoutNearTheBottomRight_staysAMarginInside()
    local Utils = Load()
    local row = Region(700, 20, 200, 22)
    local menu = Region(0, 0, 250, 300)
    Utils.OpenFlyoutBeside(menu, row, 4)
    H.assertTrue(menu.top - 300 >= Utils.MENU_EDGE, "its bottom clears the screen's by the margin")
    H.assertTrue(menu.x + 250 <= 1000 - Utils.MENU_EDGE, "and its right edge")
    H.assertTrue(menu.clamped)
    H.assertEq(menu.insets[1], -Utils.MENU_EDGE, "the clamp keeps the margin too")
end

function tests.aDropdownAtTheBottom_flipsAboveWithItsMargin()
    local Utils = Load()
    local button = Region(100, 4, 120, 20)
    local list = Region(0, 0, 160, 200)
    Utils.OpenDropdownBelow(list, button, 2)
    H.assertTrue(list.top - 200 >= Utils.MENU_EDGE)
end

local pass, fail, failures = H.runSuite("MenuScreenEdge", tests)
return { pass = pass, fail = fail, failures = failures }
