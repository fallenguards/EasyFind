-- Tests for Apps/GPS/Trip.lua: stops planned leg by leg, each from the
-- stop before, and the stop list's edits planning the trip again.
local H = require("Harness")

local function Load(opts)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    local legs = {}
    local route = { dest = { name = "C", mapID = 3, x = 0.5, y = 0.5 }, stops = opts and opts.stops }
    ns.GPS = {
        CurrentRoute = function() return route end,
        WorldPos = function(mapID, x, y) return 0, mapID * 100 + x, y end,
        BuildRoute = function(_, dest, via, _, _, _, from)
            legs[#legs + 1] = { dest = dest.name, from = from and from.name, via = via }
            local sec = dest.sec
            if sec == "none" then sec = nil elseif sec == nil then sec = 10 end
            return { { kind = "travel", name = dest.name } }, sec, { tips = dest.name }
        end,
        Plan = function(_, _, build, done) done(build()) end,
        Navigated = function(dest, steps, total, advice, stops)
            route.planned = { dest = dest, steps = steps, total = total, advice = advice, stops = stops }
        end,
        Open = function() end,
        Clear = function() route.cleared = true end,
    }
    H.loadModule("Apps/GPS/Trip.lua", env, ns)
    return ns.GPSTrip, route, legs
end

local tests = {}

function tests.build_plansEachLegFromTheStopBefore()
    local Trip, _, legs = Load()
    local a = { name = "A", mapID = 1, x = 0.2, y = 0.3, sec = 5 }
    local b = { name = "B", mapID = 2, x = 0.4, y = 0.4, sec = 7 }
    local c = { name = "C", mapID = 3, x = 0.5, y = 0.5, sec = 9 }
    local steps, total, advice = Trip.Build({ a, b, c }, "via", nil, true, "first")
    H.assertEq(#steps, 3)
    H.assertEq(total, 21)
    H.assertEq(advice.tips, "A", "the first leg's advice")
    H.assertNil(legs[1].from, "the first leg from the start as set")
    H.assertEq(legs[1].via, "via")
    H.assertEq(legs[2].from, "A")
    H.assertNil(legs[2].via, "the stop to learn is on the first leg only")
    H.assertEq(legs[3].from, "B")
end

function tests.build_unpricedLegLeavesNoTotal()
    local Trip = Load()
    local _, total = Trip.Build({ { name = "A", mapID = 1 }, { name = "B", mapID = 2, sec = "none" } })
    H.assertNil(total)
end

function tests.edits_changeTheStopsAndPlanAgain()
    local Trip, route = Load({ stops = { { name = "A", mapID = 1 }, { name = "B", mapID = 2 }, { name = "C", mapID = 3 } } })
    Trip.Move(3, 1)
    H.assertEq(route.stops[1].name, "C")
    H.assertEq(route.planned.stops[1].name, "C", "planned again in the new order")
    H.assertEq(route.planned.dest.name, "B", "the last stop is the destination")
    Trip.Remove(1)
    H.assertEq(#route.stops, 2)
    Trip.Add({ name = "D", mapID = 4 })
    H.assertEq(route.stops[3].name, "D")
    H.assertEq(#route.planned.steps, 3, "three legs planned")
    Trip.Replace(2, { name = "E", mapID = 5 })
    H.assertEq(route.planned.stops[2].name, "E")
    Trip.Remove(1)
    Trip.Remove(1)
    Trip.Remove(1)
    H.assertTrue(route.cleared, "no stop left: the route is cleared")
end

function tests.navigate_keepsAnOldRoutesOneDestination()
    local Trip, route = Load()
    H.assertTrue(Trip.Navigate({ quiet = true }))
    H.assertEq(route.planned.stops[1].name, "C")
    H.assertEq(#route.planned.stops, 1)
end

local pass, fail, failures = H.runSuite("GPSTrip", tests)
return { pass = pass, fail = fail, failures = failures }
