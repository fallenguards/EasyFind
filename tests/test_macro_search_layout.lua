-- Tests for the macro search bar's place (Search/MacroListSearch.lua): it
-- hangs from the selector, only the icons move down under it, and the
-- selector and its scroll bar are never moved or resized (skins place them).

local H = require("Harness")

local function Region(name)
    local r = { name = name, calls = {}, points = {} }
    setmetatable(r, { __index = function(self, key)
        return function(_, ...)
            self.calls[#self.calls + 1] = key
            if key == "SetPoint" then
                local point, rel, relPoint, x, y = ...
                self.points[point] = { rel = rel, relPoint = relPoint, x = x, y = y }
            end
        end
    end })
    return r
end

local function Attach()
    local sel = Region("selector")
    sel.ScrollBox = Region("scrollBox")
    sel.ScrollBar = Region("scrollBar")
    function sel:GetPadding() return 5, 5, 6, 6, 4 end
    function sel:GetStride() return 6 end
    function sel:GetButtonWidth() return 46 end
    function sel:GetFrameStrata() return "HIGH" end
    local frame = Region("MacroFrame")
    frame.MacroSelector = sel
    frame.efMacroListSearch = false
    local box
    local env = setmetatable({
        MacroFrame = frame,
        CreateFrame = function(kind)
            local f = Region(kind)
            if kind == "EditBox" then box = f end
            return f
        end,
        EventUtil = { ContinueOnAddOnLoaded = function(_, fn) fn() end },
    }, { __index = _G })
    env._G = env
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/MacroListSearch.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local ns = { Utils = { slower = string.lower, sfind = string.find } }
    assert(load(src, "=MacroListSearch.lua", "t", env))("EasyFind", ns)
    return sel, box
end

local tests = {}

function tests.theBarHangsFromTheSelector()
    local sel, box = Attach()
    local top = box.points.TOPLEFT
    H.assertTrue(top ~= nil, "the bar has a TOPLEFT point")
    H.assertTrue(top.rel == sel, "placed from the selector, so it follows a skin's move")
    H.assertEq(top.relPoint, "TOPLEFT")
    H.assertEq(top.x, 11)
    H.assertEq(top.y, -5)
end

function tests.onlyTheIconsMoveDown()
    local sel = Attach()
    local top = sel.ScrollBox.points.TOP
    H.assertTrue(top ~= nil and top.rel == sel, "the icons' box hangs lower in the selector")
    H.assertEq(top.y, -28)
end

function tests.theSelectorAndScrollBarAreLeftAlone()
    local sel = Attach()
    local moves = { SetPoint = true, ClearAllPoints = true, SetHeight = true, SetSize = true, SetWidth = true,
        SetAllPoints = true }
    for _, region in ipairs({ sel, sel.ScrollBar }) do
        for _, call in ipairs(region.calls) do
            H.assertFalse(moves[call], region.name .. " " .. call)
        end
    end
end

local pass, fail, failures = H.runSuite("MacroSearchLayout", tests)
return { pass = pass, fail = fail, failures = failures }
