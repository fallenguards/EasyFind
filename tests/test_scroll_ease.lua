-- The scroll bar's eased wheel (Shared/Utils.lua CreateMinimalScrollBar)
-- drops its target once anything else moves the list. The chat lays older
-- messages out above near the top and moves the view down to keep its place;
-- the ease, still aiming at its old offset, pulled it up again, loading more
-- each time, and a click on the jump-to-newest arrow was pulled back too.
local H = require("Harness")

local function Stub()
    local s = { alpha = 0, scripts = {} }
    return setmetatable(s, { __index = function(_, k)
        if not k:find("^%u") then return nil end
        if k == "SetScript" then return function(self, name, fn) self.scripts[name] = fn end end
        if k == "GetScript" then return function(self, name) return self.scripts[name] end end
        if k == "HookScript" then return function(self, name, fn)
            local prev = self.scripts[name]
            self.scripts[name] = function(...) if prev then prev(...) end fn(...) end
        end end
        if k == "SetAlpha" then return function(self, a) self.alpha = a end end
        if k == "GetAlpha" then return function(self) return self.alpha end end
        if k:find("^Create") then return function() return Stub() end end
        if k:find("^Get") then return function() return 0 end end
        if k:find("^Is") then return function() return true end end
        return function() end
    end })
end

local function List(range, at)
    local list = Stub()
    list.range, list.at = range, at
    list.GetVerticalScrollRange = function(self) return self.range end
    list.GetVerticalScroll = function(self) return self.at end
    list.SetVerticalScroll = function(self, v) self.at = math.max(0, math.min(self.range, v)) end
    return list
end

local function Build(list)
    local f = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local s = assert(src:find("function Utils.CreateMinimalScrollBar", 1, true), "CreateMinimalScrollBar")
    local e = select(2, assert(src:find("\n    return bar\nend\n", s, true)))
    local env = setmetatable({
        Utils = { SafeOnUpdate = function(frame, fn) frame.tick = fn end, SafeAfter = function() end },
        ns = { SCROLLBAR_THUMB_W = 4, SCROLLBAR_EDGE_INSET = 2 },
        CreateFrame = function() return Stub() end,
        GetTime = function() return 0 end, GetCursorPosition = function() return 0, 0 end,
        IsMouseButtonDown = function() return false end,
        mmin = math.min, mmax = math.max, mabs = math.abs, mfloor = math.floor,
    }, { __index = _G })
    assert(load(src:sub(s, e), "=Utils.lua CreateMinimalScrollBar", "t", env))()
    local bar = env.Utils.CreateMinimalScrollBar(list, Stub())
    local wheel = list.scripts.OnMouseWheel
    local function Frames(n) for _ = 1, n do if bar.tick then bar.tick(bar, 0.016) end end end
    return bar, wheel, Frames
end

local tests = {}

function tests.anEaseReachesItsTarget()
    local list = List(1000, 500)
    local _, wheel, Frames = Build(list)
    wheel(list, 3)
    Frames(60)
    H.assertEq(list.at, 230, "three notches up")
end

function tests.rowsLaidOutAboveStopTheEase()
    local list = List(1000, 500)
    local _, wheel, Frames = Build(list)
    wheel(list, 3)
    Frames(2)
    -- Older rows laid out above: the view moves down to keep its place.
    list.range = 1800
    list.SetVerticalScroll(list, list.at + 800)
    local kept = list.at
    Frames(60)
    H.assertEq(list.at, kept, "the view stays where its owner put it")
end

function tests.theJumpToNewestStays()
    local list = List(1000, 500)
    local _, wheel, Frames = Build(list)
    wheel(list, 5)
    Frames(1)
    list.SetVerticalScroll(list, list.range)
    Frames(60)
    H.assertEq(list.at, 1000)
end

function tests.theNextNotchStartsWhereTheViewIs()
    local list = List(1000, 500)
    local _, wheel, Frames = Build(list)
    wheel(list, 3)
    Frames(1)
    list.SetVerticalScroll(list, 900)
    wheel(list, 1)
    Frames(60)
    H.assertEq(list.at, 810, "one notch above where it was put, not four above the old aim")
end

local pass, fail, failures = H.runSuite("ScrollEase", tests)
return { pass = pass, fail = fail, failures = failures }
