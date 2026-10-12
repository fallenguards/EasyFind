-- Tests for Apps/GPS/Arrow.lua: the arrow at the character aims a little
-- ahead along the walk, turns at its bends, and finds the walk again when
-- the player strays off it.
local H = require("Harness")

-- An L-shaped walk in world yards: 100 north, then 100 west.
local function fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.UIParent = H.newFrame()
    local now = { t = 100 }
    env.GetTime = function() return now.t end
    local player = { x = 0, y = 0 }
    local finds = {}
    local route = { steps = { { kind = "travel", go = { ci = 1, wx = 100, wy = 100 } } }, active = 1 }
    ns.GPS = {
        CurrentRoute = function() return route end,
        PlayerWorldPos = function() return 1, player.x, player.y end,
    }
    ns.GPSRoute = {
        WalkPath = function(_, sx, sy, tx, ty)
            finds[#finds + 1] = { sx, sy }
            local pts = { sx, sy, 100, sy, tx, ty }
            local a = math.abs(100 - sx)
            return { pts = pts, cum = { 0, a, a + math.abs(ty - sy) }, len = a + math.abs(ty - sy) }
        end,
    }
    H.loadModule("Apps/GPS/Arrow.lua", env, ns)
    return ns.GPSArrow._Aim, player, finds, now
end

local tests = {}

function tests.alongAStraightRunItPointsAhead()
    local Aim, player = fresh()
    player.x = 50
    local px, py, ax, ay, left = Aim()
    H.assertEq(px, 50)
    H.assertEq(py, 0)
    H.assertEq(ax, 75, "a little ahead along the walk")
    H.assertEq(ay, 0)
    H.assertEq(left, 150, "the yards left on the walk")
end

function tests.nearABendItPointsRoundIt()
    local Aim, player = fresh()
    player.x = 95
    local _, _, ax, ay = Aim()
    H.assertEq(ax, 100)
    H.assertEq(ay, 20, "past the bend, not at the spot straight ahead")
end

function tests.offTheWayTheWalkIsFoundAgain()
    local Aim, player, finds, now = fresh()
    player.x = 50
    Aim()
    H.assertEq(#finds, 1)
    player.y = 40
    now.t = now.t + 5
    Aim()
    H.assertEq(#finds, 2, "found again from where the player stands")
    H.assertEq(finds[2][2], 40)
end

function tests.closeToTheWayItKeepsTheWalk()
    local Aim, player, finds, now = fresh()
    player.x = 30
    Aim()
    player.x, player.y = 60, 5
    now.t = now.t + 5
    Aim()
    H.assertEq(#finds, 1, "a few yards off is still on the way")
end

-- The bearing reads north and west off the map, whichever way the world's
-- coordinates run: map up is north, map left is west.
local function bearingWith(toWorld)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.UIParent = H.newFrame()
    env.C_Map = { GetBestMapForUnit = function() return 7 end }
    ns.GPSRoute = { WorldPos = function(_, x, y) return 1, toWorld(x, y) end }
    H.loadModule("Apps/GPS/Arrow.lua", env, ns)
    return ns.GPSArrow._Bearing
end

local function near(a, b) return math.abs(a - b) < 1e-9 end

function tests.bearingFromNorthTowardWest()
    -- x north, y west
    local Bearing = bearingWith(function(mx, my) return (0.5 - my) * 1000, (0.5 - mx) * 1000 end)
    H.assertTrue(near(Bearing(1, 0, 0, 10, 0), 0), "north is straight on")
    H.assertTrue(near(Bearing(1, 0, 0, 0, 10), math.pi / 2), "west a quarter turn left")
    -- x east, y north: the same places, other numbers
    Bearing = bearingWith(function(mx, my) return (mx - 0.5) * 1000, (0.5 - my) * 1000 end)
    H.assertTrue(near(Bearing(1, 0, 0, 0, 10), 0), "north is straight on")
    H.assertTrue(near(Bearing(1, 0, 0, -10, 0), math.pi / 2), "west a quarter turn left")
end

local pass, fail, failures = H.runSuite("GPSArrow", tests)
return { pass = pass, fail = fail, failures = failures }
