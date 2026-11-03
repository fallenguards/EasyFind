-- Toggle popups stop growing past Utils.MENU_MAX_ROWS rows tall and scroll
-- (2026-11-03): the price sources ran 30 rows down the screen. A short
-- popup fits its rows with no bar; a long one opens on its picked choice.
local H = require("Harness")

local ROW_H, PAD, TITLE_H = 22, 6, 18

-- A frame that answers every method; the sizes and the scroll it is given kept.
local function Frame()
    local f = { shown = false }
    function f:SetSize(w, h) self.w, self.h = w, h end
    function f:SetShown(v) self.shown = v end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:SetVerticalScroll(v) self.scroll = v end
    function f:GetScale() return 1 end
    function f:GetFrameStrata() return "TOOLTIP" end
    function f:GetFrameLevel() return 1 end
    function f:GetStringWidth() return 80 end
    function f:GetChecked() return false end
    function f:CreateTexture() return Frame() end
    function f:CreateFontString() return Frame() end
    function f:GetNormalTexture() return Frame() end
    -- Methods (capitalized) answer; a field never set stays nil.
    return setmetatable(f, { __index = function(_, k) if k:find("^%u") then return function() end end end })
end

local function Load()
    local env = setmetatable({}, { __index = _G })
    env.CreateFrame = function() return Frame() end
    env.UIParent = Frame()
    local bar = Frame()
    function bar:UpdateThumb(contentH, viewH) self.content, self.view = contentH, viewH end
    local noop = { __index = function() return function() end end }
    local ns = setmetatable({
        Results = {},
        Utils = setmetatable({ MENU_MAX_ROWS = 16, CreateMinimalScrollBar = function() return bar end }, noop),
    }, noop)
    assert(loadfile(H.ADDON_ROOT .. "/Shared/TogglePopup.lua", "t", env))("EasyFind", ns)
    return ns, bar
end

local function Radios(n, picked)
    local defs = { { kind = "title", label = "Prices from" } }
    for i = 1, n do
        defs[#defs + 1] = { kind = "radio", label = "Source " .. i, value = i, get = function() return picked end, set = function() end }
    end
    return defs
end

local tests = {}

function tests.aShortPopup_fitsItsRows_noBar()
    local ns, bar = Load()
    local popup = ns.ShowTogglePopup("TestPopup", Frame(), Radios(3, 1))
    H.assertEq(popup.h, TITLE_H + 3 * ROW_H + PAD * 2, "as tall as its rows")
    H.assertFalse(bar:IsShown(), "no scroll bar")
    H.assertEq(popup.scroll.scroll, 0)
end

function tests.aLongPopup_capsAtTheMenuRows_andScrolls()
    local ns, bar = Load()
    local popup = ns.ShowTogglePopup("TestPopup", Frame(), Radios(30, 1))
    local view, content = 16 * ROW_H, TITLE_H + 30 * ROW_H
    H.assertEq(popup.h, view + PAD * 2, "capped at the menu rows")
    H.assertEq(popup.body.h, content, "the rows all there, in the scroll view")
    H.assertTrue(bar:IsShown(), "a scroll bar")
    H.assertEq(bar.content, content)
    H.assertEq(bar.view, view)
    H.assertEq(popup.scroll.scroll, 0, "the pick in sight at the top")
end

function tests.aLongPopup_opensOnItsPick()
    local ns = Load()
    local popup = ns.ShowTogglePopup("TestPopup", Frame(), Radios(30, 25))
    local view, pickY = 16 * ROW_H, TITLE_H + 24 * ROW_H
    local want = math.min(TITLE_H + 30 * ROW_H - view, pickY - (view - ROW_H) / 2)
    H.assertEq(popup.scroll.scroll, want, "scrolled to the 25th")
    H.assertTrue(pickY >= want and pickY + ROW_H <= want + view, "the pick inside the view")
end

local pass, fail, failures = H.runSuite("TogglePopupCap", tests)
return { pass = pass, fail = fail, failures = failures }
