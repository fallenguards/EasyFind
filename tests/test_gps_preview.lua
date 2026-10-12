-- Tests for Apps/GPS/Preview.lua: a walk's bends drawn round, its ends and
-- its straight runs where they were.
local H = require("Harness")

local function fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    H.loadModule("Apps/GPS/Preview.lua", env, ns)
    return ns.GPSPreview._RoundBends
end

local function copy(t, n)
    local out = {}
    for i = 1, n do out[i] = t[i] end
    return out
end

-- The sharpest turn between two stretches, in degrees.
local function sharpest(p, n)
    local worst = 0
    for v = 3, n - 3, 2 do
        local ax, ay, bx, by = p[v] - p[v - 2], p[v + 1] - p[v - 1], p[v + 2] - p[v], p[v + 3] - p[v + 1]
        local la, lb = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
        local c = math.max(-1, math.min(1, (ax * bx + ay * by) / (la * lb)))
        worst = math.max(worst, math.deg(math.acos(c)))
    end
    return worst
end

local tests = {}

function tests.aRightAngleTurnsInSmallSteps()
    local Round = fresh()
    local p, n = Round({ 0, 0, 100, 0, 100, 100 }, 6, 20)
    p = copy(p, n)
    H.assertEq(p[1], 0, "starts where it started")
    H.assertEq(p[n - 1], 100, "ends where it ended")
    H.assertEq(p[n], 100)
    H.assertTrue(sharpest(p, n) <= 16, "no turn above the step, got " .. sharpest(p, n))
    for v = 1, n, 2 do
        local away = math.sqrt((p[v] - 100) ^ 2 + p[v + 1] ^ 2)
        H.assertTrue(away >= 20 * 0.3 or v == 1 or v == n - 1, "the corner is cut, not kept")
    end
end

function tests.aStraightRunKeepsItsPoints()
    local Round = fresh()
    local _, n = Round({ 0, 0, 50, 0.5, 100, 0 }, 6, 20)
    H.assertEq(n, 6, "a turn under the threshold stays a single point")
end

function tests.aShortSideLimitsTheCut()
    local Round = fresh()
    local p, n = Round({ 0, 0, 10, 0, 10, 100 }, 6, 20)
    p = copy(p, n)
    H.assertTrue(p[3] >= 5, "never cut back past half the short side, got " .. p[3])
end

local pass, fail, failures = H.runSuite("GPSPreview", tests)
return { pass = pass, fail = fail, failures = failures }
