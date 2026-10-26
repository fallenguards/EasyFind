-- A step clicked on a GPS surface shows its mark on the map pulsing
-- (Apps/GPS/Preview.lua): it grows and settles a set number of times and
-- stops; clicked again it pulses again, and never hides the step.
local H = require("Harness")

local function Region()
    local r = {}
    function r:CreateAnimationGroup()
        local g = { playing = false, plays = 0, scripts = {} }
        function g:SetLooping(v) self.looping = v end
        function g:CreateAnimation() return setmetatable({}, { __index = function() return function() end end }) end
        function g:SetScript(name, fn) self.scripts[name] = fn end
        function g:Stop() self.playing = false end
        function g:Play() self.playing, self.plays = true, self.plays + 1 end
        function g:Loop() if self.scripts.OnLoop then self.scripts.OnLoop(self) end end
        return g
    end
    return r
end

local function Pulse()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/Preview.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local PULSE_SCALE", 1, true))
    local at = assert(src:find("local function Pulse", s, true))
    local _, e = assert(src:find("\nend\r?\n", at))
    return assert(load(src:sub(s, e) .. "\nreturn Pulse, PULSE_BOUNCES", "=Preview.lua pulse", "t", _G))()
end

local tests = {}

function tests.aMarkPulsesAFewTimesAndStops()
    local pulse, bounces = Pulse()
    local mark = Region()
    pulse(mark)
    local g = mark.clickPulse
    H.assertEq(g.looping, "BOUNCE")
    H.assertTrue(g.playing)
    for _ = 1, bounces - 1 do g:Loop() end
    H.assertTrue(g.playing, "still going before its last bounce")
    g:Loop()
    H.assertFalse(g.playing, "stopped after " .. bounces)
end

function tests.clickedAgain_itPulsesAgain()
    local pulse, bounces = Pulse()
    local mark = Region()
    pulse(mark)
    for _ = 1, bounces do mark.clickPulse:Loop() end
    pulse(mark)
    H.assertTrue(mark.clickPulse.playing)
    H.assertEq(mark.clickPulse.plays, 2, "the same animation, played again")
end

function tests.aSecondClick_neverHidesTheStep()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/Preview.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertNil(src:find("pinned = false", 1, true), "no click puts the step away")
end

local pass, fail, failures = H.runSuite("GPSPreviewPulse", tests)
return { pass = pass, fail = fail, failures = failures }
