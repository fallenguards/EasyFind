-- Tests for Apps/GPS/Arrow.lua and Follow.lua: the arrow at the character
-- aims a little ahead along the walk, turns at its bends, leads alongside
-- the walk a few yards out, and finds the walk again when the player strays.
local H = require("Harness")

-- An L-shaped walk in world yards: 100 north, then 100 west (opts.ty: fewer);
-- found from where the player stands, or with planned, from where the route
-- was planned. opts.pts draws another walk from its ends. With opts.planner,
-- only the walk from the planned start is drawn; others wait for
-- planner.draw(), as the game's planner draws them in its slices.
local function fresh(planned, opts)
    opts = opts or {}
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.UIParent = H.newFrame()
    local now = { t = 100 }
    env.GetTime = function() return now.t end
    local player = { x = 0, y = 0 }
    local finds = {}
    local clear = { v = true }
    local route = { steps = { { kind = "travel", go = { ci = 1, wx = 100, wy = opts.ty or 100 } } }, active = 1,
                    from = planned and { ci = 1, wx = 0, wy = 0 } or nil }
    local planner = { asked = {}, drawn = {} }
    function planner.draw()
        for _, a in ipairs(planner.asked) do planner.drawn[a[1] .. ":" .. a[2]] = true end
    end
    ns.GPS = {
        CurrentRoute = function() return route end,
        PlayerWorldPos = function() return 1, player.x, player.y end,
        DrawWalk = function(_, sx, sy) planner.asked[#planner.asked + 1] = { sx, sy } return true end,
    }
    ns.GPSRoute = {
        WalkPath = function(_, sx, sy, tx, ty, lazy)
            if opts.planner and lazy and not (sx == 0 and sy == 0) and not planner.drawn[sx .. ":" .. sy] then
                return nil
            end
            finds[#finds + 1] = { sx, sy }
            local pts = opts.pts and opts.pts(sx, sy, tx, ty) or { sx, sy, 100, sy, tx, ty }
            local cum, len = { 0 }, 0
            for v = 2, #pts / 2 do
                len = len + math.sqrt((pts[2 * v - 1] - pts[2 * v - 3]) ^ 2 + (pts[2 * v] - pts[2 * v - 2]) ^ 2)
                cum[v] = len
            end
            return { pts = pts, cum = cum, len = len }
        end,
    }
    ns.GPSNav = { Straight = function() return clear.v end }
    H.loadModule("Apps/GPS/Follow.lua", env, ns)
    H.loadModule("Apps/GPS/Arrow.lua", env, ns)
    return ns.GPSArrow._Aim, player, finds, now, clear, planner
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
    local Aim, player = fresh(false, { ty = 30 })
    player.x = 95
    local _, _, ax, ay = Aim()
    H.assertEq(ax, 100)
    H.assertEq(ay, 20, "past the bend, not at the spot straight ahead")
end

function tests.aWalkHardlyLongerThanTheLineAimsAtTheSpot()
    -- From (0,0) to (100,100) by way of (52,48): a wiggle, not a way round.
    local Aim, player = fresh(true, { pts = function(sx, sy, tx, ty) return { sx, sy, 52, 48, tx, ty } end })
    player.x, player.y = 0, 0
    local _, _, ax, ay = Aim()
    H.assertEq(ax, 100, "the spot itself, not a point along the wiggle")
    H.assertEq(ay, 100)
end

function tests.aWayRoundHardlyLongerIsFollowed()
    -- From (0,0) to (100,0) by way of (50,-20): only 8% longer, but 20 yards
    -- off the line, as a walk out along a pier to its end.
    local Aim, player = fresh(true, { ty = 0, pts = function(sx, sy, tx, ty) return { sx, sy, 50, -20, tx, ty } end })
    player.x, player.y = 0, 0
    local _, _, ax, ay = Aim()
    H.assertTrue(ay < -5, "along the walk, not across to the spot")
    H.assertTrue(ax > 20 and ax < 30)
end

function tests.aWalkFoundAgainIsDrawnByThePlanner()
    local Aim, player, _, now, _, planner = fresh(true, { planner = true })
    player.x = 50
    Aim()
    H.assertEq(#planner.asked, 0, "the walk from the planned start is drawn already")
    player.y = 40
    now.t = now.t + 5
    local _, _, ax, ay = Aim()
    H.assertEq(#planner.asked, 1, "the walk from here is asked of the planner")
    H.assertEq(planner.asked[1][2], 40)
    H.assertEq(ax, 100, "straight at the spot meanwhile")
    H.assertEq(ay, 100)
    now.t = now.t + 1
    Aim()
    H.assertEq(#planner.asked, 1, "asked once while it draws")
    planner.draw()
    now.t = now.t + 1
    _, _, ax, ay = Aim()
    H.assertEq(ax, 75, "then followed from here")
    H.assertEq(ay, 40)
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

function tests.theWalkRunsFromWhereTheRouteWasPlanned()
    local Aim, player, finds = fresh(true)
    player.x = 50
    Aim()
    H.assertEq(finds[1][1], 0)
    H.assertEq(finds[1][2], 0)
end

local function near(a, b) return math.abs(a - b) < 1e-9 end

function tests.besideTheWalkItLeadsAlongside()
    local Aim, player = fresh(true)
    player.x, player.y = 50, 6
    local _, _, ax, ay = Aim()
    H.assertTrue(near(ax, 75))
    H.assertTrue(near(ay, 6), "alongside the walk, not back onto it: " .. ay)
end

function tests.fartherOutItLeadsBackToTheLane()
    local Aim, player = fresh(true)
    player.x, player.y = 50, 15
    local _, _, ax, ay = Aim()
    H.assertTrue(near(ax, 75))
    H.assertTrue(near(ay, 10), "back to 10 yd beside the walk: " .. ay)
end

function tests.withSomethingBetweenItLeadsOntoTheWalk()
    local Aim, player, _, _, clear = fresh(true)
    clear.v = false
    player.x, player.y = 50, 6
    local _, _, ax, ay = Aim()
    H.assertTrue(near(ax, 75))
    H.assertTrue(near(ay, 0))
end

function tests.nearTheEndItMakesForTheSpot()
    local Aim, player = fresh(true)
    player.x, player.y = 106, 90
    local _, _, ax, ay, left = Aim()
    H.assertTrue(near(left, 10))
    H.assertTrue(near(ax, 100) and near(ay, 100), "the spot itself: " .. ax .. "," .. ay)
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
    H.loadModule("Apps/GPS/Follow.lua", env, ns)
    H.loadModule("Apps/GPS/Arrow.lua", env, ns)
    return ns.GPSArrow._Bearing
end

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
