-- Tests for Apps/GPS/Boats.lua: one ride from a stop to the next times its
-- route, and every later departure follows from the route's timetable.
local H = require("Harness")

local function fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.EasyFind.db = {}
    local pos = { ci = 1, x = 0, y = 0 }
    local clock = { t = 1000 }
    env.C_Map = {
        GetBestMapForUnit = function() return 5 end,
        GetPlayerMapPosition = function() return { GetXY = function() return 0.5, 0.5 end } end,
        GetWorldPosFromMapPos = function() return pos.ci, { GetXY = function() return pos.x, pos.y end } end,
    }
    env.IsPlayerMoving = function() return false end
    env.GetServerTime = function() return clock.t end
    env.GetRealmName = function() return "Realm" end
    ns.GPSData = { routes = { [7] = { period = 300, stops = {
        { ci = 1, wx = 0, wy = 0, dwell = 60, at = 0 },
        { ci = 1, wx = 1000, wy = 0, dwell = 60, at = 150 },
    } } } }
    H.loadModule("Apps/GPS/Boats.lua", env, ns)
    local function step(x, y, dt)
        pos.x, pos.y = x, y
        clock.t = clock.t + (dt or 1)
        ns.GPSBoats._Sample()
    end
    return ns.GPSBoats, step, clock, env
end

local tests = {}

function tests.untimedRouteHasNoWait()
    local Boats = fresh()
    H.assertNil(Boats.WaitAt(7, 1, 0))
end

function tests.aRideTimesTheRoute()
    local Boats, step, clock = fresh()
    step(0, 0)                 -- on the pier
    step(0, 0)
    local left = clock.t       -- the boat pulls away during the next second
    for x = 30, 990, 30 do step(x, 0) end
    for _ = 1, 4 do step(1000, 0) end   -- docked at the far stop
    -- It left the first stop about at `left`: it next leaves the second
    -- stop 150 s after that, then every 300 s.
    local wait = Boats.WaitAt(7, 2, 0)
    local expect = (left + 150 - clock.t) % 300
    H.assertTrue(math.abs(wait - expect) <= 1, "wait " .. tostring(wait) .. " vs " .. expect)
    -- Arriving 300 s later waits as long: the loop repeats.
    H.assertTrue(math.abs(Boats.WaitAt(7, 2, 300) - wait) < 0.01)
end

function tests.walkingIsNoRide()
    local Boats, step, _, env = fresh()
    env.IsPlayerMoving = function() return true end
    step(0, 0)
    for x = 30, 990, 30 do step(x, 0) end
    for _ = 1, 4 do step(1000, 0) end
    H.assertNil(Boats.WaitAt(7, 2, 0), "running along the shore times nothing")
end

-- On board: standing still on a docked boat's deck (only open water under
-- it on the walking grid, beside its boarding spot), or carried once it sails.
function tests.aboard_onTheDeckOrUnderWay()
    local Boats, step, _, env = fresh()
    local open = { ["20:0"] = true }
    env.EasyFind._ns.GPSNav = { OpenWater = function(_, x, y) return open[x .. ":" .. y] or false end }
    env.IsSwimming = function() return false end
    env.IsFalling = function() return false end
    H.assertFalse(Boats.Aboard(1, 0, 0, 1, 0, 0), "on the pier")
    H.assertTrue(Boats.Aboard(1, 20, 0, 1, 0, 0), "on the deck at the dock")
    H.assertFalse(Boats.Aboard(1, 20, 0, 1, 100, 0), "open water far from where it is boarded")
    env.IsSwimming = function() return true end
    H.assertFalse(Boats.Aboard(1, 20, 0, 1, 0, 0), "swimming beside it")
    env.IsSwimming = function() return false end
    step(0, 0)
    step(0, 0)
    for x = 30, 300, 30 do step(x, 0) end
    H.assertTrue(Boats.Carried(), "under way")
    H.assertTrue(Boats.Aboard(1, 300, 0, 1, 0, 0), "on board wherever it is")
end

local pass, fail, failures = H.runSuite("GPSBoats", tests)
return { pass = pass, fail = fail, failures = failures }
