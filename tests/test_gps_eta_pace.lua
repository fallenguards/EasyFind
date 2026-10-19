-- Tests for the time still to go while following a route (Apps/GPS/GPS.lua
-- RemainingSeconds): steps aside and shuffles on the spot never move the
-- trip's time by more than the yards they cover; the pace the game gives
-- (on foot where a mount was planned) still sets the later walks.
local H = require("Harness")

local function Load(planned)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("-- The step followed:", 1, true), "RemainingSeconds not in GPS.lua")
    local e = assert(src:find("-- The time still to go in minutes", s, true), "end of RemainingSeconds not found")
    local clock = { t = 100 }
    local reading = { along = 0, path = { len = 1000, time = 1000 } }
    local unit = { now = 7, run = 7 }
    local env = setmetatable({
        GetTime = function() return clock.t end,
        GetUnitSpeed = function() return unit.now, unit.run, unit.run, 4.72 end,
        UnitOnTaxi = function() return false end,
        issecretvalue = function(v) return type(v) == "table" end,
        mmax = math.max, mmin = math.min,
        ns = {
            GPSData = {},
            GPSRoute = {
                GroundSpeed = function() return planned end,
                TravelSeconds = function(_, yards) return yards / planned end,
            },
            GPSFollow = { Now = function() return reading end },
        },
    }, { __index = _G })
    local RemainingSeconds = assert(load(src:sub(s, e - 1) .. "\nreturn RemainingSeconds", "=GPS.lua RemainingSeconds", "t", env))()
    -- A walk of 1000 yd, then 20 minutes of walking steps after it.
    local route = { active = 1, steps = { { kind = "travel" }, { kind = "travel", sec = 1200 } } }
    local function Tick(along)
        clock.t = clock.t + 1
        reading.along = along
        return RemainingSeconds(route)
    end
    return Tick, unit
end

-- Ten seconds on along the walk at 7 yd/s: the time then.
local function WalkOn(Tick)
    local eta
    for k = 1, 10 do eta = Tick(7 * k) end
    return eta
end

local tests = {}

function tests.shufflingOnTheSpotHoldsTheTime()
    local Tick = Load(7)
    local before = WalkOn(Tick)
    local worst = 0
    for k = 1, 40 do
        local eta = Tick(70 + (k % 2))
        worst = math.max(worst, math.abs(eta - before))
    end
    H.assertTrue(worst < 30, "a yard aside moved the time by " .. math.floor(worst) .. " s")
end

function tests.aStepPastABendMovesItByItsYardsOnly()
    local Tick = Load(7)
    local before = WalkOn(Tick)
    local worst = 0
    for k = 1, 40 do
        local eta = Tick(k % 2 == 1 and 120 or 70)
        worst = math.max(worst, math.abs(eta - before))
    end
    H.assertTrue(worst < 30, "a step to the far side of a bend moved the time by " .. math.floor(worst) .. " s")
end

function tests.onFootWhereAMountWasPlannedTheLaterWalksSlow()
    local Tick, unit = Load(14)
    unit.now, unit.run = 7, 7
    local eta
    for k = 1, 30 do eta = Tick(7 * k) end
    local walkLeft = (1000 - 210) / 7
    H.assertTrue(math.abs(eta - (walkLeft + 2400)) < 60, "on foot, the walks at the run pace: " .. math.floor(eta))
end

function tests.standingStillKeepsThePlannedPace()
    local Tick, unit = Load(14)
    unit.now, unit.run = 0, 7
    local eta
    for _ = 1, 20 do eta = Tick(0) end
    H.assertTrue(math.abs(eta - (1000 / 14 + 1200)) < 5, "nothing seen yet: the plan's pace: " .. math.floor(eta))
end

function tests.aWithheldPaceIsLeftAlone()
    local Tick, unit = Load(7)
    local before = WalkOn(Tick)
    local secret = setmetatable({}, { __lt = function() error("compared a secret") end })
    unit.now, unit.run = secret, secret
    local ok, eta = pcall(Tick, 77)
    H.assertTrue(ok, tostring(eta))
    H.assertTrue(math.abs(eta - before) < 30, "the time kept: " .. tostring(eta))
end

local pass, fail, failures = H.runSuite("GPSEtaPace", tests)
return { pass = pass, fail = fail, failures = failures }
