-- Tests for Apps/GPS/Preview.lua: a walk's bends drawn round, its ends and
-- its straight runs where they were.
local H = require("Harness")

local function fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    H.loadModule("Apps/GPS/Preview.lua", env, ns)
    return ns.GPSPreview._RoundBends, ns.GPSPreview._Offsets
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

-- Each corner of a strip lies h from both stretches it joins, so the strips
-- meet edge to edge and each one's edges run parallel to it.
function tests.stripCornersSitOnBothEdges()
    local Round, Offsets = fresh()
    local p, n = Round({ 0, 0, 100, 0, 140, 60, 260, 40 }, 8, 20)
    p = copy(p, n)
    local h = 5
    local ox, oy = Offsets(p, n, h)
    local function away(k, s)   -- corner k's distance from stretch s's line
        local x1, y1, x2, y2 = p[2 * s - 1], p[2 * s], p[2 * s + 1], p[2 * s + 2]
        local dx, dy = x2 - x1, y2 - y1
        local cx, cy = p[2 * k - 1] + ox[k], p[2 * k] + oy[k]
        return math.abs((cx - x1) * dy - (cy - y1) * dx) / math.sqrt(dx * dx + dy * dy)
    end
    for k = 1, n / 2 do
        if k > 1 then H.assertTrue(math.abs(away(k, k - 1) - h) < 1e-6, "corner " .. k .. " on the stretch before") end
        if k < n / 2 then H.assertTrue(math.abs(away(k, k) - h) < 1e-6, "corner " .. k .. " on the stretch after") end
    end
end

-- A leg running off the open map is drawn up to its edge, not dropped.
function tests.aLegOffTheMapIsCutAtItsEdge()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    H.loadModule("Apps/GPS/Preview.lua", env, ns)
    local OnMap = ns.GPSPreview._OnMap
    local t0, t1 = OnMap(0.5, 0.5, 1.5, 0.5)
    H.assertEq(t0, 0)
    H.assertEq(t1, 0.5, "cut where it leaves the map")
    t0, t1 = OnMap(-1, 0.25, 1, 0.25)
    H.assertEq(t0, 0.5, "starts where it comes onto the map")
    H.assertEq(t1, 1)
    H.assertNil(OnMap(1.2, 0, 1.2, 1), "nothing of it on the map")
end

local pass, fail, failures = H.runSuite("GPSPreview", tests)
return { pass = pass, fail = fail, failures = failures }
