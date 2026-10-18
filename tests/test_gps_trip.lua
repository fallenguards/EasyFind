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
    return ns.GPSTrip, route, legs, ns
end

-- The route ahead: one walk east on continent 1 from (0, 0) to (1000, 0),
-- 100 seconds; spots are world yards. now: the arrow's place on it.
local function Walking(ns, route, now)
    route.steps = { { kind = "travel", sec = 100, arrive = { ci = 1, wx = 1000, wy = 0 } } }
    ns.GPSData = {}
    ns.GPSRoute = {
        GroundSpeed = function() return 10 end,
        WalkPath = function() return { pts = { 0, 0, 1000, 0 }, len = 1000 } end,
    }
    ns.GPSFollow = {
        Now = function() return now end,
        StartOf = function() return 1, 0, 0 end,
    }
    ns.GPS.WorldPos = function(_, x, y) return 1, x, y end
end

local function near(a, b) return math.abs(a - b) < 0.01 end

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

function tests.insert_aStopBeforeTheDestination()
    local Trip, route = Load()
    Trip.Insert({ name = "Inn", mapID = 9 })
    H.assertEq(route.stops[1].name, "Inn")
    H.assertEq(route.stops[2].name, "C", "the destination stays last")
    H.assertEq(route.planned.dest.name, "C")
end

-- The extra way through a spot, off the walk, at the walk's own pace
-- (100 s for 1000 yards); five minutes at most.
function tests.detour_theExtraWayAtTheWalksPace()
    local Trip, route, _, ns = Load()
    Walking(ns, route)
    local detour = Trip.Detour(route)
    H.assertTrue(near(detour(1, 500, 100), 1.98), "100 yards off the middle")
    H.assertTrue(near(detour(1, 500, 1900), 292.94), "just within five minutes")
    H.assertNil(detour(1, 500, 2000), "past five minutes")
    H.assertNil(detour(2, 500, 0), "another continent")
end

function tests.detour_onlyTheWayAhead()
    local Trip, route, _, ns = Load()
    -- The player 600 yards along: a spot by the start is behind them.
    Walking(ns, route, { route = route, index = 1, seg = 1, px = 600, py = 0,
                         path = { pts = { 0, 0, 1000, 0 }, len = 1000 } })
    H.assertTrue(near(Trip.Detour(route)(1, 100, 0), 100), "back 500 yards and on again")
    route.steps[1].kind = "taxi"
    H.assertNil(Trip.Detour(route), "no stop on a flight")
end

function tests.along_theLeastOutOfTheWayFirst()
    local Trip, route, _, ns = Load()
    Walking(ns, route)
    ns.GPS.CanNavigate = function() return true end
    ns.GPS.EtaText = function(sec) return math.floor(sec / 60 + 0.5) .. " min" end
    ns.L.GPS_ALONG_ADDS_FMT, ns.L.GPS_ALONG_ON_WAY = "+%s", "on the way"
    ns.GPS.SearchPlaces = function()
        return {
            { name = "Far", mapID = 1, x = 500, y = 1500 },
            { name = "Near", mapID = 1, x = 500, y = 100 },
            { name = "Off", mapID = 1, x = 500, y = 5000 },
            { name = "Catalog", mapID = 1, x = 500, y = 0, catalog = true },
        }
    end
    local asked
    ns.GPSNpcs = {
        Append = function(out, _, q, _, _, along)
            asked = q
            if along(1, 500, 50) then out[#out + 1] = { name = "Innkeeper", mapID = 1, x = 500, y = 50 } end
        end,
    }
    local list, secs = Trip.AlongPlaces("inn")
    H.assertEq(asked, "inn", "the creatures searched along the way")
    H.assertEq(#list, 3, "the one too far off and the search's own creature left out")
    H.assertEq(list[1].name, "Innkeeper")
    H.assertEq(list[2].name, "Near")
    H.assertEq(list[3].name, "Far")
    H.assertEq(Trip.AddsText(secs[list[2]]), "on the way")
    H.assertEq(Trip.AddsText(secs[list[3]]), "+4 min")
end

local pass, fail, failures = H.runSuite("GPSTrip", tests)
return { pass = pass, fail = fail, failures = failures }
