-- Route engine tests: straight travel, folded flight legs, a portal across
-- continents, a teleport from the start, faction-locked transport.
local H = require("Harness")

-- Two continents: map 1 is continent 1, map 2 is continent 2. Map units
-- are 10000 yards square so distances are easy to read.
-- pre(env): the client as it is before Route.lua loads.
local function fresh(pre)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    local function vec(x, y)
        return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
    end
    env.CreateVector2D = vec
    env.C_Map = {
        GetMapInfo = function(m) return { name = "Map " .. tostring(m) } end,
        GetBestMapForUnit = function() return nil end,
        GetWorldPosFromMapPos = function(m, v)
            return (m == 2) and 2 or 1, vec(v.x * 10000, v.y * 10000)
        end,
    }
    env.GetTime = function() return 0 end
    if pre then pre(env) end
    H.loadModule("Apps/GPS/Route.lua", env, ns)
    H.assertNotNil(ns.GPSRoute, "Route.lua must populate ns.GPSRoute")
    return env, ns, ns.GPSRoute
end

local function P(m, x, y)
    return { m = m, x = x, y = y, ci = (m == 2) and 2 or 1, wx = x * 10000, wy = y * 10000 }
end

local function data()
    return {
        speeds = { run = 7, mount = 10, fly = 20, taxi = 40 },
        nodes = {
            [1] = { n = "Alpha", m = 1, x = 0.1, y = 0.1, ci = 1, wx = 1000, wy = 1000 },
            [2] = { n = "Beta", m = 1, x = 0.9, y = 0.1, ci = 1, wx = 9000, wy = 1000 },
            [3] = { n = "Gamma", m = 1, x = 0.9, y = 0.9, ci = 1, wx = 9000, wy = 9000 },
        },
        legs = { { 1, 2, 8000 }, { 2, 3, 8000 } },
        edges = {
            { kind = "portal", n = "Portal to Map 2", from = P(1, 0.5, 0.5), to = P(2, 0.5, 0.5), sec = 14 },
            { kind = "boat", n = "Horde boat", from = P(1, 0.1, 0.12), to = P(2, 0.5, 0.59), sec = 1, faction = "Horde", bidir = true },
        },
        abilities = {
            { id = 8690, n = "Hearthstone", item = 6948, cd = 1800, cast = 10, to = P(2, 0.2, 0.2) },
        },
    }
end

-- Every step, the ways to a flight master, dock or portal included; a
-- rider at 10 yards a second unless a test says.
local function buildAll(Route, startPoint, dest, extra)
    local opts = { data = data(), start = startPoint, faction = "Alliance", canFly = false, groundSpeed = 10,
                   owns = function() return false end, cooldown = function() return 0 end }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return Route:Build(dest, opts)
end

-- The steps that do something: the ways to them left out, so a test about
-- a crossing reads its crossing.
local function build(Route, startPoint, dest, extra)
    local steps, total, advice = buildAll(Route, startPoint, dest, extra)
    if not steps then return nil end
    local out = {}
    for i = 1, #steps do
        if not steps[i].approach then out[#out + 1] = steps[i] end
    end
    return out, total, advice
end

local tests = {}

function tests.sameContinent_isOneTravelStep()
    local _, _, Route = fresh()
    local steps, total = build(Route, P(1, 0.1, 0.1), { name = "Nearby", mapID = 1, x = 0.2, y = 0.1 })
    H.assertEq(#steps, 1)
    H.assertEq(steps[1].kind, "travel")
    H.assertEq(steps[1].mapID, 1)
    H.assertTrue(math.abs(total - 102) < 0.5, "1000 yd at 10 yd/s plus mounting: " .. tostring(total))
end

function tests.flightLegs_foldIntoOneFlight()
    local _, _, Route = fresh()
    local steps, total = build(Route, P(1, 0.1, 0.11), { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 })
    H.assertEq(#steps, 2, "the flight and the last leg")
    H.assertEq(steps[1].kind, "taxi")
    H.assertEq(steps[1].arrive.wx, 9000)
    H.assertEq(steps[1].arrive.wy, 9000)
    H.assertEq(steps[1].go.wx, 1000, "the flight step is pinned at the departure node")
    H.assertEq(steps[2].kind, "travel")
    H.assertTrue(total < 500, "two legs at taxi speed beat 11314 yd on a mount: " .. tostring(total))
end

function tests.crossContinent_usesThePortal()
    local _, _, Route = fresh()
    local steps = build(Route, P(1, 0.1, 0.1), { name = "Over there", mapID = 2, x = 0.5, y = 0.6 })
    H.assertEq(#steps, 2, "the portal and the last leg")
    H.assertEq(steps[1].kind, "portal")
    H.assertEq(steps[1].go.wx, 5000, "the portal step is pinned at the portal spot")
    H.assertEq(steps[1].arrive.ci, 2)
    H.assertEq(steps[2].kind, "travel")
    H.assertEq(steps[2].arrive.ci, 2)
end

function tests.teleport_fromTheStartWhenCheaper()
    local _, _, Route = fresh()
    local steps, total = build(Route, P(1, 0.1, 0.1), { name = "Over there", mapID = 2, x = 0.5, y = 0.6 },
        { owns = function() return true end })
    H.assertEq(steps[1].kind, "teleport")
    H.assertEq(steps[1].spellID, 8690)
    H.assertEq(steps[2].kind, "travel")
    H.assertTrue(total < 600, "hearth then ride beats the portal walk: " .. tostring(total))
end

function tests.teleport_notTakenBehindALongCooldown()
    local _, _, Route = fresh()
    local steps = build(Route, P(1, 0.1, 0.1), { name = "Over there", mapID = 2, x = 0.5, y = 0.6 },
        { owns = function() return true end, cooldown = function() return 1500 end })
    H.assertEq(steps[1].kind, "portal")
end

function tests.factionEdge_onlyForItsFaction()
    local _, _, Route = fresh()
    local alliance = build(Route, P(1, 0.1, 0.1), { name = "Over there", mapID = 2, x = 0.5, y = 0.6 })
    H.assertEq(alliance[1].kind, "portal", "Alliance never boards the Horde boat")
    local horde = build(Route, P(1, 0.1, 0.1), { name = "Over there", mapID = 2, x = 0.5, y = 0.6 }, { faction = "Horde" })
    H.assertEq(horde[1].kind, "boat")
end

-- A flight lands only at a discovered point; an unmet flight master can
-- start one, so the route may walk there, learn it and fly on.
function tests.undiscoveredFlightPoint_isNeverFlownThrough()
    local _, _, Route = fresh()
    local dest = { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 }
    local steps = build(Route, P(1, 0.1, 0.11), dest, { known = { [1] = true, [3] = true } })
    for i = 1, #steps do
        if steps[i].kind == "taxi" then
            H.assertEq(steps[i].nodeID, 2, "a flight here can only start at the undiscovered middle point")
            H.assertTrue(steps[i].learn, "and says to learn it first")
        end
    end
    local flown = build(Route, P(1, 0.1, 0.11), dest, { known = { [1] = true, [2] = true, [3] = true } })
    H.assertEq(flown[1].kind, "taxi", "all three discovered: the flight is back")
    H.assertEq(flown[1].nodeID, 1)
    H.assertNil(flown[1].learn)
end

function tests.flightNeverLandsAtUndiscovered()
    local _, _, Route = fresh()
    local steps = build(Route, P(1, 0.1, 0.11), { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 }, { known = { [1] = true } })
    for i = 1, #steps do
        H.assertTrue(steps[i].kind ~= "taxi", "neither the middle nor the far point is learned: no flight lands")
    end
end

function tests.undiscoveredStart_learnsAndFlies()
    local _, ns, Route = fresh()
    ns.L.GPS_STEP_FLY_NEW_FMT = "Learn the flight path at %s, then fly to %s"
    local steps = build(Route, P(1, 0.9, 0.1), { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 }, { known = { [3] = true } })
    H.assertEq(steps[1].kind, "taxi")
    H.assertTrue(steps[1].learn, "the flight starts at a master this character has not met")
    H.assertEq(steps[1].text, "Learn the flight path at Beta, then fly to Gamma")
end

-- Advice: the flight path whose discovery would shorten this trip next
-- time, and the undiscovered masters a ride passes on the way.
function tests.advice_namesTheFlightPathWorthLearning()
    local _, _, Route = fresh()
    local steps, total, advice = build(Route, P(1, 0.1, 0.11), { name = "Far corner", mapID = 1, x = 0.9, y = 0.9 },
        { known = { [1] = true, [2] = true } })
    H.assertEq(steps[1].kind, "taxi", "fly to the discovered middle point")
    H.assertNotNil(advice and advice.learn, "the far point would save the long ride")
    H.assertEq(advice.learn.id, 3)
    H.assertTrue(advice.learn.save > 500, "8000 yd on a mount against a 200 s flight: " .. tostring(advice.learn.save))
    H.assertTrue(advice.learn.total < total, "the trip with it learned is shorter")
    -- The way that trip goes, rides and flights only: here its one flight
    -- (the test's L gives the key back).
    local way = advice.learn.way or {}
    H.assertEq(#way, 1, "one ride: " .. table.concat(way, " | "))
    H.assertTrue(way[1]:find("FLY", 1, true) ~= nil, "a flight: " .. tostring(way[1]))
end

-- A stop to learn a flight master: there, learn it, then fly on from it.
function tests.stop_learnsThereThenFliesOn()
    local _, _, Route = fresh()
    local d = data()
    d.edges, d.abilities = {}, {}
    local dest = { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 }
    local via = { id = 2, name = "Beta", p = P(1, 0.9, 0.1) }
    local steps, total = buildAll(Route, P(1, 0.1, 0.11), dest, { data = d, known = { [1] = true, [3] = true }, via = via })
    H.assertTrue(steps ~= nil, "a route with the stop")
    local learnAt, flyAfter
    for i = 1, #steps do
        if steps[i].kind == "learn" then learnAt = i end
        if learnAt and i > learnAt and steps[i].kind == "taxi" then flyAfter = steps[i] end
    end
    H.assertTrue(learnAt ~= nil, "a step to learn Beta")
    H.assertEq(steps[learnAt].nodeID, 2)
    H.assertTrue(flyAfter ~= nil and flyAfter.nodeID == 2, "then a flight from Beta, now learned")
    local sum = 0
    for i = 1, #steps do sum = sum + (steps[i].sec or 0) end
    H.assertEq(math.floor(sum + 0.5), math.floor(total + 0.5), "the total is its steps")
end

-- The tip for a flight path elsewhere carries what the stop costs now.
function tests.advice_pricesTheDetour()
    local _, _, Route = fresh()
    local _, total, advice = build(Route, P(1, 0.1, 0.11), { name = "Far corner", mapID = 1, x = 0.9, y = 0.9 },
        { known = { [1] = true, [2] = true } })
    local learn = advice and advice.learn
    H.assertTrue(learn ~= nil and learn.extra ~= nil, "the detour is priced")
    H.assertTrue(math.abs(learn.viaTotal - (total + learn.extra)) < 0.01, "extra is the trip with the stop, less the trip")
    H.assertTrue(learn.extra > 0, "Gamma is out of the way")
end

function tests.advice_listsMastersOnTheWay()
    local _, _, Route = fresh()
    local d = data()
    d.nodes[4] = { n = "Delta", m = 1, x = 0.5, y = 0.105, ci = 1, wx = 5000, wy = 1050 }
    d.legs = {}
    d.edges = {}
    d.abilities = {}
    local _, _, advice = build(Route, P(1, 0.1, 0.1), { name = "Along the road", mapID = 1, x = 0.9, y = 0.11 },
        { data = d, known = {} })
    H.assertNotNil(advice, "undiscovered masters lie on the road")
    local names = {}
    for i = 1, #advice.pickups do names[advice.pickups[i].name] = true end
    H.assertTrue(names.Delta, "the one a few yards off the road is on the way")
    H.assertNil(names.Gamma, "the one 8000 yd off the road is not")
end

function tests.noAdvice_whenTheClientCannotSay()
    local _, _, Route = fresh()
    local _, _, advice = build(Route, P(1, 0.1, 0.11), { name = "Far corner", mapID = 1, x = 0.9, y = 0.9 }, { known = false })
    H.assertNil(advice, "every point counts as learned: nothing to suggest")
end

-- A boat's cost is the ride plus the average wait for it.
function tests.transportWait_isPartOfTheCost()
    local _, ns, Route = fresh()
    ns.L.GPS_STEP_BOAT_FMT = "Board the boat to %s"
    local d = data()
    d.edges = { { kind = "boat", n = "Boat to Map 2", dest = "Harbor", from = P(1, 0.1, 0.12), to = P(2, 0.5, 0.59), sec = 60, wait = 120 } }
    d.abilities = {}
    local steps = build(Route, P(1, 0.1, 0.1), { name = "Over there", mapID = 2, x = 0.5, y = 0.6 }, { data = d })
    H.assertEq(steps[1].kind, "boat")
    H.assertEq(steps[1].wait, 120)
    H.assertEq(steps[1].edgeSec, 60, "the ride alone")
    H.assertTrue(steps[1].sec >= 180, "the step counts the wait: " .. tostring(steps[1].sec))
    H.assertTrue(steps[1].text:find("Harbor", 1, true) ~= nil, "the dock's name: " .. steps[1].text)
end

-- On board, a crossing's step says to stay on until it lands.
function tests.transport_onBoardSaysStayOnUntilItLands()
    local _, ns, Route = fresh()
    ns.L.GPS_STEP_BOAT_FMT = "Board the boat to %s"
    ns.L.GPS_STEP_BOAT_ABOARD_FMT = "Stay on the boat until %s"
    local d = data()
    d.edges = { { kind = "boat", n = "Boat to Map 2", dest = "Harbor", from = P(1, 0.1, 0.12), to = P(2, 0.5, 0.59), sec = 60, wait = 120 } }
    d.abilities = {}
    local steps = build(Route, P(1, 0.1, 0.1), { name = "Over there", mapID = 2, x = 0.5, y = 0.6 }, { data = d })
    H.assertEq(steps[1].kind, "boat")
    H.assertEq(steps[1].aboardText, "Stay on the boat until Harbor")
end

-- The recorder stores Enum.FlightPathFaction: 1 Horde, 2 Alliance.
function tests.factionDigits_areFactions()
    local _, _, Route = fresh()
    local d = data()
    d.nodes[1].faction, d.nodes[2].faction, d.nodes[3].faction = "2", "2", "2"
    local dest = { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 }
    local alliance = build(Route, P(1, 0.1, 0.11), dest, { data = d })
    H.assertEq(alliance[1].kind, "taxi", "Alliance flies Alliance flight masters")
    local horde = build(Route, P(1, 0.1, 0.11), dest, { data = d, faction = "Horde" })
    for i = 1, #horde do H.assertTrue(horde[i].kind ~= "taxi", "Horde never does") end
end

-- The 1.x game: no flying, the character's own pace, roads that wind.
function tests.classic_groundPace()
    local _, _, Route = fresh()
    local d = data()
    d.classic = true
    d.edges, d.abilities, d.legs = {}, {}, {}
    local _, total = build(Route, P(1, 0.1, 0.1), { name = "Nearby", mapID = 1, x = 0.2, y = 0.1 }, { data = d, groundSpeed = 7 })
    H.assertTrue(math.abs(total - 1000 * 1.2 / 7) < 0.5, "on foot, no mounting, 1.2 yards walked per yard: " .. tostring(total))
end

-- A teleport landing a short ride from the start is never offered, even
-- when it lands a little nearer the goal.
function tests.teleport_notTakenWhenItLandsNearby()
    local _, _, Route = fresh()
    local d = data()
    d.edges, d.legs = {}, {}
    d.abilities = { { id = 8690, n = "Hearthstone", item = 6948, cd = 1800, cast = 10, to = P(1, 0.15, 0.1) } }
    local steps = build(Route, P(1, 0.1, 0.1), { name = "Down the road", mapID = 1, x = 0.4, y = 0.1 },
        { data = d, owns = function() return true end })
    for i = 1, #steps do H.assertTrue(steps[i].kind ~= "teleport", "a hearth 500 yd away is not a trip") end
end

-- An island is not walked to: the route takes the boat even when the
-- straight line across the water is shorter.
function tests.island_isReachedByBoatNotOnFoot()
    local _, _, Route = fresh()
    local d = data()
    d.legs, d.abilities = {}, {}
    d.edges = { { kind = "boat", n = "Boat to the island", dest = "Isle", from = P(1, 0.1, 0.12), to = P(1, 0.5, 0.55), sec = 300, wait = 120 } }
    d.edges[1].to.m = 3
    d.landmass = { zones = { [3] = "isle" } }
    local steps = build(Route, P(1, 0.1, 0.1), { name = "On the isle", mapID = 3, x = 0.5, y = 0.6 }, { data = d })
    H.assertEq(steps[1].kind, "boat", "no walking across to the isle")
    local nodata = build(Route, P(1, 0.1, 0.1), { name = "On the isle", mapID = 3, x = 0.5, y = 0.6 }, { data = data() })
    H.assertTrue(nodata ~= nil, "without landmass data every spot on a continent is walkable, as before")
end

-- A crossing still a way off says which dock to head for.
function tests.crossing_namesItsDockWhileFar()
    local _, ns, Route = fresh()
    ns.L.GPS_REACH_BOAT_FMT = "Go to the dock for the boat to %s"
    local d = data()
    d.edges = { { kind = "boat", n = "Boat to Map 2", dest = "Harbor", from = P(1, 0.1, 0.12), to = P(2, 0.5, 0.59), sec = 60, wait = 120 } }
    d.abilities = {}
    local steps = build(Route, P(1, 0.1, 0.1), { name = "Over there", mapID = 2, x = 0.5, y = 0.6 }, { data = d })
    H.assertEq(steps[1].reachText, "Go to the dock for the boat to Harbor")
end

-- On the 1.x game, a client that cannot say which flight masters are
-- learned means none are, except those seen at a flight master.
function tests.classic_unknownFlightsAreNotAssumed()
    local _, _, Route = fresh()
    local d = data()
    d.classic = true
    local dest = { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 }
    local steps = build(Route, P(1, 0.1, 0.11), dest, { data = d, known = nil })
    for i = 1, #steps do H.assertTrue(steps[i].kind ~= "taxi", "nothing learned, nothing flown") end
    Route.recordedKnown = { [1] = true, [2] = true, [3] = true }
    local seen = build(Route, P(1, 0.1, 0.11), dest, { data = d, known = nil })
    Route.recordedKnown = nil
    H.assertEq(seen[1].kind, "taxi", "the ones seen at a flight master fly")
end

-- Forever's map listing marks every point discovered, learned or not: a
-- flight lands only where a flight master's own map showed it learned.
function tests.classic_listingSaysAllDiscovered_onlyRecordedFly()
    local env, _, Route = fresh()
    local d = data()
    d.classic = true
    env.C_TaxiMap = { GetTaxiNodesForMap = function(m)
        if m ~= 1 then return {} end
        return { { nodeID = 1, name = "Alpha", isUndiscovered = false }, { nodeID = 2, name = "Beta", isUndiscovered = false },
                 { nodeID = 3, name = "Gamma", isUndiscovered = false } }
    end }
    Route.ForgetKnown()
    Route.recordedKnown = { [1] = true }
    local steps = build(Route, P(1, 0.1, 0.11), { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 }, { data = d, known = nil })
    Route.recordedKnown = nil
    for i = 1, #steps do H.assertTrue(steps[i].kind ~= "taxi", "no flight lands at a master never met") end
end

-- The other faction's boat is a last resort: taken when nothing else gets
-- there, and said so on the step.
function tests.otherFactionBoat_isALastResort()
    local _, _, Route = fresh()
    local d = data()
    d.legs, d.abilities = {}, {}
    d.edges = { { kind = "boat", n = "Horde boat", dest = "Isle", from = P(1, 0.1, 0.12), to = P(1, 0.5, 0.55), sec = 60, faction = "Horde" } }
    d.edges[1].to.m = 3
    d.landmass = { zones = { [3] = "isle" } }
    local steps = build(Route, P(1, 0.1, 0.1), { name = "On the isle", mapID = 3, x = 0.5, y = 0.6 }, { data = d })
    H.assertEq(steps[1].kind, "boat", "the only way there")
    H.assertTrue(steps[1].hostile, "marked as the other side's")
    H.assertEq(steps[1].sec, 60, "the step shows the ride, not the penalty")
end

-- A race-locked route is offered to that race alone.
function tests.raceLockedRoute_isForThatRaceOnly()
    local _, _, Route = fresh()
    local d = data()
    d.legs, d.abilities = {}, {}
    d.edges = { { kind = "skyship", n = "Skyship", dest = "Isle", from = P(1, 0.1, 0.12), to = P(1, 0.5, 0.55), sec = 60, race = "Skyborne" } }
    d.edges[1].to.m = 3
    d.landmass = { zones = { [3] = "isle" } }
    local dest = { name = "On the isle", mapID = 3, x = 0.5, y = 0.6 }
    local sky = build(Route, P(1, 0.1, 0.1), dest, { data = d, race = "Skyborne" })
    H.assertEq(sky[1].kind, "skyship")
    local human = build(Route, P(1, 0.1, 0.1), dest, { data = d, race = "Human" })
    H.assertNil(human, "no way there for anyone else")
end

-- A hearth lands in the town this character is bound to.
function tests.hearth_landsInTheBoundTown()
    local env, _, Route = fresh()
    env.C_Map.GetAreaInfo = function(area) return area == 87 and "Goldshire" or nil end
    local d = data()
    d.edges = {}
    d.binds = { [87] = P(2, 0.5, 0.55) }
    d.abilities = { { id = 8690, n = "Hearthstone", item = 6948, cd = 1800, cast = 10, bind = "hearth" } }
    local steps = build(Route, P(1, 0.1, 0.1), { name = "Over there", mapID = 2, x = 0.5, y = 0.6 },
        { data = d, bindName = "Goldshire", owns = function() return true end })
    H.assertEq(steps[1].kind, "teleport")
    H.assertEq(steps[1].arrive.wx, 5000, "lands at the bound town's spot")
end

-- Bound at Darnassus' inn, the game names the district (Craftsmen's
-- Terrace), not the town: the town's spot through its district.
function tests.hearth_boundInADistrictLandsInItsTown()
    local env, _, Route = fresh()
    local names = { [1657] = "Darnassus", [1659] = "Craftsmen's Terrace" }
    env.C_Map.GetAreaInfo = function(area) return names[area] end
    local d = data()
    d.edges = {}
    d.binds = { [1657] = P(2, 0.5, 0.55) }
    d.bindAreas = { [1659] = 1657 }
    d.abilities = { { id = 8690, n = "Hearthstone", item = 6948, cd = 1800, cast = 10, bind = "hearth" } }
    local steps = build(Route, P(1, 0.1, 0.1), { name = "Darnassus", mapID = 2, x = 0.5, y = 0.6 },
        { data = d, bindName = "Craftsmen's Terrace", owns = function() return true end })
    H.assertEq(steps[1].kind, "teleport", "the hearth, not the long way")
    H.assertEq(steps[1].arrive.wx, 5000, "lands at the town's spot")
end

function tests.gatedMarker_isNotOffered()
    local _, _, Route = fresh()
    local d = data()
    d.edges[1].poi = true
    d.edges[2] = nil   -- the portal alone: no other way across
    local dest = { name = "Over there", mapID = 2, x = 0.5, y = 0.6 }
    local asked = {}
    local none = build(Route, P(1, 0.1, 0.1), dest, { data = d, hasMarker = function(m, name) asked[#asked + 1] = name return false end })
    H.assertNil(none, "the only crossing is a marker this character cannot see")
    H.assertEq(asked[1], "Portal to Map 2", "the check names the marker on its map")
    local shown = build(Route, P(1, 0.1, 0.1), dest, { data = d, hasMarker = function() return true end })
    H.assertEq(shown[1].kind, "portal")
    local unknown = build(Route, P(1, 0.1, 0.1), dest, { data = d, hasMarker = function() return nil end })
    H.assertEq(unknown[1].kind, "portal", "when the client cannot say, the crossing is offered")
end

-- A seam (Khaz Algar's Coreway: the continent id changes, no loading screen)
-- is plain travel: one step, no portal wording.
function tests.seam_isPlainTravel()
    local _, _, Route = fresh()
    local d = data()
    d.edges = { { kind = "seam", n = "The Coreway", from = P(1, 0.9, 0.5), to = P(2, 0.1, 0.5), sec = 1, bidir = true } }
    d.abilities = {}
    local steps, total = build(Route, P(1, 0.1, 0.5), { name = "Under the mountain", mapID = 2, x = 0.12, y = 0.5 }, { data = d })
    H.assertEq(#steps, 1, "one travel step through the seam")
    H.assertEq(steps[1].kind, "travel")
    H.assertEq(steps[1].arrive.ci, 2)
    H.assertTrue(total > 800 and total < 830, "8000 yd then 200 yd at 10 yd/s: " .. tostring(total))
end

-- A portal whose arrival is the destination itself ends the route there:
-- no detour through another point to "reach" a spot you stand on.
function tests.portalArrivalOnTheGoal_endsThere()
    local _, _, Route = fresh()
    local d = data()
    d.edges = {
        { kind = "portal", n = "Portal to Map 2", from = P(1, 0.5, 0.5), to = P(2, 0.5, 0.5), sec = 14 },
        { kind = "portal", n = "Portal back to Map 1", from = P(2, 0.55, 0.5), to = P(1, 0.5, 0.5), sec = 14 },
    }
    d.abilities = {}
    local steps = build(Route, P(1, 0.1, 0.5), { name = "Map 2 middle", mapID = 2, x = 0.5, y = 0.5 }, { data = d })
    H.assertEq(#steps, 1, "take the portal, done: " .. #steps .. " steps")
    H.assertEq(steps[1].kind, "portal")
end

-- A zone goal ends where a crossing lands inside it, with no walk on to its
-- middle; so the crossing chosen is the quickest way in, not the nearest to it.
function tests.zoneGoal_endsWhereTheCrossingLands()
    local _, ns, Route = fresh()
    ns.L.GPS_STEP_ARRIVE_IN_FMT = "Arrive in %s"
    local d = data()
    d.legs, d.abilities = {}, {}
    d.edges = {
        { kind = "boat", n = "Boat to the far shore", from = P(1, 0.1, 0.12), to = P(2, 0.1, 0.1), sec = 60 },
        { kind = "portal", n = "Portal to the middle", from = P(1, 0.1, 0.5), to = P(2, 0.5, 0.5), sec = 14 },
    }
    local spot = build(Route, P(1, 0.1, 0.1), { name = "Map 2", mapID = 2, x = 0.5, y = 0.5 }, { data = d })
    H.assertEq(spot[1].kind, "portal", "to the middle itself the portal is quicker")
    local steps = buildAll(Route, P(1, 0.1, 0.1), { name = "Map 2", mapID = 2, x = 0.5, y = 0.5, zone = true }, { data = d })
    local last = steps[#steps]
    H.assertEq(steps[#steps - 1].kind, "boat", "into the zone the boat is quicker")
    H.assertEq(last.text, "Arrive in Map 2")
    H.assertEq(last.sec, 0)
    H.assertEq(last.arrive.wx, 1000, "where the boat lands")
end

-- Two portals at one map spot on different floors: the step names the
-- floor from the recorded height.
function tests.stackedPortals_nameTheFloor()
    local _, _, Route = fresh()
    local d = data()
    local lowFrom = P(1, 0.5, 0.5); lowFrom.fl = "lower"
    local highFrom = P(1, 0.5, 0.501); highFrom.fl = "upper"
    d.edges = {
        { kind = "portal", n = "Portal to Map 2", from = lowFrom, to = P(2, 0.5, 0.5), sec = 14 },
        { kind = "portal", n = "Portal to Map 3", from = highFrom, to = P(2, 0.9, 0.9), sec = 14 },
    }
    d.abilities = {}
    local steps = build(Route, P(1, 0.1, 0.5), { name = "Over there", mapID = 2, x = 0.5, y = 0.6 }, { data = d })
    H.assertEq(steps[1].kind, "portal")
    H.assertEq(steps[1].floor, "lower", "the lower of two stacked portals")
    local far = build(Route, P(1, 0.1, 0.5), { name = "Far corner", mapID = 2, x = 0.9, y = 0.9 }, { data = d })
    H.assertEq(far[1].floor, "upper")
    H.assertTrue(far[1].text:find("upper", 1, true) ~= nil or far[1].text:find("GPS_FLOOR_UPPER", 1, true) ~= nil, "the text names the floor: " .. far[1].text)
end

-- The way to a portal, dock or flight master is its own step, named by
-- what is taken there and pinned at it, near or far; the crossing follows.
function tests.wayToACrossing_isItsOwnStep()
    local _, ns, Route = fresh()
    ns.L.GPS_REACH_PORTAL_FMT = "Go to the portal to %s"
    ns.L.GPS_REACH_FLIGHT_FMT = "Go to the flight master at %s"
    local d = data()
    d.edges = {
        { kind = "portal", n = "Portal to Map 2", dest = "Map 2", from = P(3, 0.5, 0.5), to = P(2, 0.5, 0.5), sec = 14 },
    }
    d.abilities = {}
    local steps = buildAll(Route, P(1, 0.1, 0.1), { name = "Over there", mapID = 2, x = 0.5, y = 0.6 }, { data = d })
    H.assertEq(#steps, 3, "go there, take it, finish: " .. #steps .. " steps")
    H.assertTrue(steps[1].approach, "the way there")
    H.assertEq(steps[1].text, "Go to the portal to Map 2")
    H.assertEq(steps[1].arrive.wx, 5000, "it ends at the portal")
    H.assertTrue(steps[1].sec > 400, "the walk is priced on the way step: " .. tostring(steps[1].sec))
    H.assertEq(steps[2].kind, "portal")
    H.assertEq(steps[2].sec, 14, "the portal step is the portal alone")
    -- A portal a short ride away still gets its way step.
    d.edges[1].from = P(1, 0.12, 0.1)
    local near = buildAll(Route, P(1, 0.1, 0.1), { name = "Over there", mapID = 2, x = 0.5, y = 0.6 }, { data = d })
    H.assertTrue(near[1].approach, "200 yd away is still a step")
    H.assertEq(near[2].kind, "portal")
    -- A flight: go to the master, then fly.
    local flown = buildAll(Route, P(1, 0.1, 0.13), { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 })
    H.assertEq(flown[1].text, "Go to the flight master at Alpha")
    H.assertEq(flown[2].kind, "taxi")
    -- Standing on the spot: no way step at all.
    local here = buildAll(Route, P(1, 0.1, 0.1), { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 })
    H.assertEq(here[1].kind, "taxi")
end

function tests.noData_returnsNil()
    local _, _, Route = fresh()
    H.assertNil(Route:Build({ name = "x", mapID = 1, x = 0.5, y = 0.5 }, { data = nil, start = P(1, 0.1, 0.1) }))
end

-- A stand-in walking grid (Nav.lua): way(sx, sy, tx, ty) gives the walk's
-- points (world x north, y west), or nil where no way on foot leads.
local function withNav(ns, way)
    local function path(_, sx, sy, tx, ty)
        local pts = way(sx, sy, tx, ty)
        if not pts then return nil end
        local len = 0
        for v = 3, #pts, 2 do len = len + math.sqrt((pts[v] - pts[v - 2]) ^ 2 + (pts[v + 1] - pts[v - 1]) ^ 2) end
        return pts, len
    end
    ns.GPSNav = {
        Ensure = function() return true end,
        Has = function() return true end,
        CostOverTime = function() return 1 end,
        Path = path,
        -- opts.near: the end may be that far off, toward the start. The
        -- time is the cost: dry ground on a road.
        Walk = function(ci, sx, sy, tx, ty, opts)
            local near = opts and opts.near
            if near then
                local d = math.sqrt((tx - sx) ^ 2 + (ty - sy) ^ 2)
                local f = d > 0 and math.min(1, near * 0.9 / d) or 0
                tx, ty = tx + (sx - tx) * f, ty + (sy - ty) * f
            end
            local cost = select(2, path(ci, sx, sy, tx, ty))
            return cost, nil, cost
        end,
    }
end

-- West from A (0, 0) to the junction B (0, 1000), then north to C (1000, 1000).
local function junction(sx, sy, tx, ty) return { sx, sy, 0, 0, 0, 1000, 1000, 1000, tx, ty } end

function tests.walk_followsTheWayOnFoot()
    local _, ns, Route = fresh()
    withNav(ns, junction)
    local path = Route.WalkPath(1, 0, -50, 1050, 1000)
    H.assertEq(#path.pts / 2, 5, "start, A, B, C, end")
    H.assertEq(math.floor(path.len + 0.5), 2100)
    H.assertEq(math.floor(path.cum[3] + 0.5), 1050, "yards so far at B")
end

function tests.walk_noGridOrNoWay()
    local _, ns, Route = fresh()
    H.assertNil(Route.WalkPath(1, 0, 0, 500, 500), "no walking grid: nothing known")
    withNav(ns, function() return nil end)
    H.assertEq(Route.WalkPath(1, 0, 0, 500, 500), false, "the grid says no way on foot")
end

-- A walk takes as long as its way on foot, not the straight line across.
function tests.walk_priceTheWalk()
    local _, ns, Route = fresh()
    withNav(ns, junction)
    local d = data()
    d.classic = true
    d.edges, d.abilities, d.legs = {}, {}, {}
    local steps, total = build(Route, P(1, 0, -0.005), { name = "Spot", mapID = 1, x = 0.105, y = 0.1 }, { data = d, groundSpeed = 7 })
    H.assertEq(#steps, 1)
    H.assertTrue(math.abs(total - 2100 / 7) < 0.5, "2100 yd on foot: " .. tostring(total))
    H.assertTrue(math.abs(steps[1].wind - 2100 / 1484.6) < 0.01, "yards walked per straight yard: " .. tostring(steps[1].wind))
    local left = Route:TravelSeconds(500, { data = d, canFly = false, groundSpeed = 7, wind = steps[1].wind })
    H.assertTrue(math.abs(left - 500 * steps[1].wind / 7) < 0.01, "the way left winds as the whole walk does")
end

-- A zone's middle off the ground the walks know (Winterspring's): the
-- nearest ground stands for it, so the route walks there, not nowhere.
function tests.walk_zoneMiddleOffTheGround_walksToTheNearestGround()
    local _, ns, Route = fresh()
    withNav(ns, function(sx, sy, tx, ty)
        if math.abs(tx - 5000) < 20 and math.abs(ty - 5000) < 20 then return nil end
        return { sx, sy, tx, ty }
    end)
    local d = data()
    d.classic = true
    d.edges, d.abilities, d.legs = {}, {}, {}
    local zone = { name = "Zone", mapID = 3, x = 0.5, y = 0.5, zone = true }
    H.assertNil(build(Route, P(1, 0.1, 0.1), zone, { data = d, groundSpeed = 7 }), "no way to the middle itself")
    ns.GPSNav.Ground = function(_, x, y) return x + 100, y end
    local steps = build(Route, P(1, 0.1, 0.1), zone, { data = d, groundSpeed = 7 })
    H.assertNotNil(steps, "a route")
    H.assertEq(steps[#steps].arrive.wx, 5100, "it ends on the ground beside the middle")
end

-- A spot reached only round by a far shore (a trainer just off a bank the
-- grid does not step down from) is walked to within 8 yards when that is
-- far shorter; a way only somewhat longer keeps the spot itself.
function tests.walk_aSpotReachedOnlyFarRoundEndsBesideIt()
    local _, ns, Route = fresh()
    withNav(ns, function(sx, sy, tx, ty)
        if math.abs(tx - 1050) < 0.01 and math.abs(ty - 1000) < 0.01 then
            return { sx, sy, 0, 3000, 3000, 3000, tx, ty }
        end
        return { sx, sy, tx, ty }
    end)
    local d = data()
    d.classic = true
    d.edges, d.abilities, d.legs = {}, {}, {}
    local spot = { name = "Trainer", mapID = 1, x = 0.105, y = 0.1 }
    local steps, total = build(Route, P(1, 0, -0.005), spot, { data = d, groundSpeed = 7 })
    H.assertEq(steps[#steps].near, 8, "the walk ends within the arrival's reach")
    H.assertTrue(total < 1484.6 / 7 + 1, "priced the short way: " .. tostring(total))

    -- From the start only, 1.4 times the line: no near end anywhere.
    withNav(ns, function(sx, sy, tx, ty)
        if math.abs(sx) < 0.01 and math.abs(sy + 50) < 0.01 and math.abs(tx - 1050) < 0.01 and math.abs(ty - 1000) < 0.01 then
            return { sx, sy, 0, 1000, tx, ty }
        end
        return { sx, sy, tx, ty }
    end)
    steps = build(Route, P(1, 0, -0.005), spot, { data = d, groundSpeed = 7 })
    H.assertNil(steps[#steps].near, "somewhat longer: the spot itself")
end

-- Without a walking grid, the straight line stands, with the 1.x detour.
function tests.walk_noGridKeepsTheStraightPrice()
    local _, _, Route = fresh()
    local d = data()
    d.classic = true
    d.edges, d.abilities, d.legs = {}, {}, {}
    local steps, total = build(Route, P(1, 0.5, 0.5), { name = "Far off", mapID = 1, x = 0.6, y = 0.5 }, { data = d, groundSpeed = 7 })
    H.assertTrue(math.abs(total - 1000 * 1.2 / 7) < 0.5, tostring(total))
    H.assertNil(steps[1].wind)
end

-- No way on foot: the walk is shut, not priced as the straight line.
function tests.walk_noWayOnFootTakesAnotherWay()
    local _, ns, Route = fresh()
    withNav(ns, function() return nil end)
    local d = data()
    d.classic = true
    d.edges, d.abilities, d.legs = {}, {}, {}
    local steps = build(Route, P(1, 0.5, 0.5), { name = "Far off", mapID = 1, x = 0.6, y = 0.5 }, { data = d, groundSpeed = 7 })
    H.assertNil(steps, "nothing gets there")
end

-- From Alpha to the spot the way on foot goes round a U of 6000 yd past a
-- 2000 yd line; a dock halfway along the line splits nothing, as walking
-- from it goes round too.
local function aroundTheU(sx, sy, tx, ty)
    if (sx < 2500) ~= (tx < 2500) then return { sx, sy, sx, 3000, tx, 3000, tx, ty } end
    return { sx, sy, tx, ty }
end

function tests.walk_windingWalkLosesToTheFlight()
    local _, ns, Route = fresh()
    withNav(ns, aroundTheU)
    local d = data()
    d.classic = true
    d.abilities = {}
    d.nodes = { [1] = { n = "Alpha", m = 1, x = 0.1, y = 0.1, ci = 1, wx = 1000, wy = 1000 },
                [2] = { n = "Delta", m = 1, x = 0.3, y = 0.11, ci = 1, wx = 3000, wy = 1100 } }
    d.legs = { { 1, 2, 2000, 300 } }
    d.edges = { { kind = "portal", n = "Portal to Map 2", from = P(1, 0.2, 0.1), to = P(2, 0.5, 0.5), sec = 14 } }
    local steps, total = build(Route, P(1, 0.1, 0.1), { name = "Spot", mapID = 1, x = 0.3, y = 0.1 },
                               { data = d, groundSpeed = 10, known = false })
    H.assertEq(steps[1].kind, "taxi", "the 300 s flight beats 6000 yd round the U")
    H.assertTrue(math.abs(total - 316) < 1, "board, fly, then 100 yd on foot: " .. tostring(total))
end

-- The junction walk crosses three zones: Alpha until 500 yd west, Bravo up
-- to 500 yd north of the junction, Charlie beyond.
local function zoneAt(_, x, y)
    if y < 500 then return 10, "Alpha" end
    if x < 500 then return 11, "Bravo" end
    return 12, "Charlie"
end

-- The walk, its way drawn, as the planner leaves it before the split: a
-- walk not drawn yet is never split.
local function walk(Route)
    local target = { ci = 1, wx = 1050, wy = 1000, m = 12, x = 0.1, y = 0.1 }
    local start = { ci = 1, wx = 0, wy = -50 }
    if Route then Route.WalkPath(1, start.wx, start.wy, target.wx, target.wy) end
    return { { kind = "travel", text = "Travel to Spot", mapID = 12, go = target, arrive = target, sec = 210 } },
        start, target
end

function tests.walk_notDrawnYetStaysWhole()
    local _, ns, Route = fresh()
    withNav(ns, junction)
    local steps, start = walk()
    H.assertEq(#Route.SplitWalks(steps, start, data(), { zoneAt = zoneAt }), 1, "its way is not drawn: whole")
    H.assertNil(Route.WalkPath(1, 0, -50, 1050, 1000, true), "and asking lazily draws nothing")
end

function tests.walk_splitsIntoAStepPerZone()
    local _, ns, Route = fresh()
    withNav(ns, junction)
    local steps, start, target = walk(Route)
    local out = Route.SplitWalks(steps, start, data(), { zoneAt = zoneAt })
    H.assertEq(#out, 3, "Alpha, Bravo, Charlie")
    H.assertEq(out[1].enter, 11, "the first ends on entering Bravo")
    H.assertEq(out[1].walkZone, 10)
    H.assertEq(out[2].enter, 12)
    H.assertNil(out[3].enter, "the last ends at the spot")
    H.assertEq(out[3].arrive, target)
    H.assertEq(out[3].text, "Travel to Spot", "the last keeps what the step said")
    H.assertTrue(math.abs(out[1].sec + out[2].sec + out[3].sec - 210) < 0.01, "the time is shared out")
    H.assertTrue(out[1].arrive.wy >= 500 and out[1].arrive.wy <= 600, "the border on the way west")
    H.assertTrue(math.abs(out[1].wind - 1) < 0.01, "Alpha is a straight stretch")
    H.assertTrue(out[2].wind > 1.3, "Bravo turns at the junction: " .. tostring(out[2].wind))
end

-- A route keeps its drawn walks: put back in a later session they are
-- found without a search (a route in progress at login drew every walk
-- again, about a second of the GPS at 6 to 10 ms a frame).
function tests.savedWalk_isFoundAgainWithoutASearch()
    local _, ns, Route = fresh()
    withNav(ns, junction)
    local searches = 0
    local path = ns.GPSNav.Path
    ns.GPSNav.Path = function(...) searches = searches + 1 return path(...) end
    local drawn = Route.WalkPath(1, 0, -50, 1050, 1000)
    local w = Route.SaveWalk(1, 0, -50, 1050, 1000)
    Route.ForgetWalkPaths()
    Route.KeepWalk(w)
    local again = Route.WalkPath(1, 0, -50, 1050, 1000)
    H.assertEq(searches, 1, "the way back came without a search")
    H.assertEq(again.len, drawn.len)
    H.assertEq(#again.pts, #drawn.pts)
    H.assertEq(math.floor(again.cum[3] + 0.5), 1050, "yards so far, worked out again")
    withNav(ns, function() return nil end)
    H.assertEq(Route.WalkPath(1, 0, 0, 500, 500), false)
    local none = Route.SaveWalk(1, 0, 0, 500, 500)
    Route.ForgetWalkPaths()
    Route.KeepWalk(none)
    H.assertEq(Route.WalkPath(1, 0, 0, 500, 500, true), false, "no way on foot is kept too")
    H.assertNil(Route.SaveWalk(1, 9, 9, 99, 99), "a walk not drawn is not saved")
end

-- A flown leg goes straight: the job after the route shows draws no walk
-- for it and splits none by zone (Silvermoon to Undercity flew, then was
-- redrawn as a walk with a ledge to jump).
function tests.flownLeg_isNeverRedrawnAsAWalk()
    local _, ns, Route = fresh()
    withNav(ns, junction)
    local d = data()
    d.edges, d.abilities, d.legs = {}, {}, {}
    local start = P(1, 0, -0.005)
    local steps = buildAll(Route, start, { name = "Spot", mapID = 1, x = 0.105, y = 0.1 },
                           { data = d, canFly = true, flySpeed = 20 })
    H.assertEq(#steps, 1)
    H.assertTrue(steps[1].fly, "the leg is flown")
    Route.DrawWalks(steps, start)
    H.assertNil(Route.WalkPath(1, 0, -50, 1050, 1000, true), "no walk drawn for it")
    local out = Route.SplitWalks(steps, start, d, { zoneAt = zoneAt })
    H.assertEq(#out, 1, "one straight leg, not a step per zone")
    H.assertEq(out[1], steps[1])
end

-- Along a border the way crosses it back and forth: Alpha and Bravo by
-- turns in 200 yd bands on the way west, Charlie past 500 yd north.
local function zoneAlongBorder(_, x, y)
    if x >= 500 then return 12, "Charlie" end
    if y < 200 or (y >= 400 and y < 600) then return 10, "Alpha" end
    return 11, "Bravo"
end

function tests.walk_alongABorderEachZoneIsOneStep()
    local _, ns, Route = fresh()
    withNav(ns, junction)
    local steps, start = walk(Route)
    local out = Route.SplitWalks(steps, start, data(), { zoneAt = zoneAlongBorder })
    H.assertEq(#out, 3, "Alpha, Bravo, Charlie, not Alpha and Bravo by turns: " .. #out)
    H.assertEq(out[1].walkZone, 10)
    H.assertEq(out[1].enter, 11)
    H.assertTrue(out[1].arrive.wy >= 600 and out[1].arrive.wy <= 700,
        "Alpha runs to where the way leaves it last: " .. tostring(out[1].arrive.wy))
    H.assertEq(out[2].walkZone, 11)
    H.assertEq(out[2].enter, 12)
end

function tests.walk_toAZoneEndsOnEnteringIt()
    local _, ns, Route = fresh()
    withNav(ns, junction)
    local steps, start, target = walk(Route)
    local out = Route.SplitWalks(steps, start, data(), { zoneAt = zoneAt, goalZone = 12 })
    H.assertEq(#out, 2, "no step inside the goal zone")
    H.assertEq(out[2].enter, 12)
    H.assertTrue(out[2].arrive ~= target and out[2].arrive.wx >= 500 and out[2].arrive.wx <= 600,
        "the walk ends at the goal zone's border, not its middle")
    H.assertEq(out[2].arrive.m, 11, "the border placed on the zone before")
    -- The border lies 1050 yd in (A to B) plus the way north to it.
    H.assertTrue(math.abs(out[1].sec + out[2].sec - 210 * (1050 + out[2].arrive.wx) / 2100) < 1,
        "the time runs to the border: " .. tostring(out[1].sec + out[2].sec))
    -- Each piece's way is kept as the walk between its ends: followed and
    -- drawn from the cache, no search.
    local a = out[1].arrive
    local piece = Route.WalkPath(1, a.wx, a.wy, out[2].arrive.wx, out[2].arrive.wy)
    H.assertTrue(piece and piece.len > 0 and piece.pts[1] == a.wx and piece.pts[2] == a.wy, "the second piece's way starts at the first border")
    H.assertTrue(math.abs(piece.len - ((1000 - a.wy) + out[2].arrive.wx)) < 1, "and runs by B to the goal's border: " .. tostring(piece.len))
    local first = Route.WalkPath(1, start.wx, start.wy, a.wx, a.wy)
    H.assertTrue(first and math.abs(first.len - (a.wy - start.wy)) < 1, "the first piece's way runs west to the border")
end

function tests.walk_fromInsideACityStartsWithLeavingIt()
    local _, ns, Route = fresh()
    withNav(ns, junction)
    local steps, start = walk(Route)
    local out = Route.SplitWalks(steps, start, data(), {
        zoneAt = zoneAt, isCity = function(m) return m == 99 end, startCity = { map = 99, name = "City" } })
    H.assertEq(#out, 4)
    H.assertEq(out[1].walkZone, 99, "the city first")
    H.assertEq(out[1].enter, 10, "done on entering the zone around it")
end

function tests.walk_wholeWalksStayOneStep()
    local _, ns, Route = fresh()
    withNav(ns, junction)
    local steps, start = walk(Route)
    local out = Route.SplitWalks(steps, start, data(), { zoneAt = zoneAt, wholeWalks = true })
    H.assertEq(#out, 1, "three zones, one step")
    H.assertTrue(out[1] == steps[1], "the walk as planned")
end

function tests.walk_wholeIntoAZoneStillEndsAtItsBorder()
    local _, ns, Route = fresh()
    withNav(ns, junction)
    local steps, start, target = walk(Route)
    local out = Route.SplitWalks(steps, start, data(), { zoneAt = zoneAt, goalZone = 12, wholeWalks = true })
    H.assertEq(#out, 1, "Alpha and Bravo in one step")
    H.assertEq(out[1].text, "Travel to Spot", "in the walk's own words")
    H.assertEq(out[1].enter, 12, "done on entering the goal zone")
    H.assertTrue(out[1].arrive ~= target and out[1].arrive.wx >= 500 and out[1].arrive.wx <= 600, "at its border")
    H.assertTrue(math.abs(out[1].sec - 210 * (1050 + out[1].arrive.wx) / 2100) < 1,
        "the time runs to the border: " .. tostring(out[1].sec))
    local way = Route.WalkPath(1, start.wx, start.wy, out[1].arrive.wx, out[1].arrive.wy)
    H.assertTrue(way and math.abs(way.len - (1050 + out[1].arrive.wx)) < 1, "its way kept from the start: " .. tostring(way and way.len))
end

function tests.walk_inOneZoneOrWithoutAGridStaysOneStep()
    local _, ns, Route = fresh()
    withNav(ns, junction)
    local steps, start = walk(Route)
    H.assertEq(#Route.SplitWalks(steps, start, data(), { zoneAt = function() return 10, "Alpha" end }), 1)
    local _, _, Bare = fresh()
    H.assertEq(#Bare.SplitWalks(steps, start, data(), { zoneAt = zoneAt }), 1, "no walking grid")
end

-- Avoiding flights: the route walks instead, its time the walk's own.
function tests.avoid_flightsWalksInstead()
    local _, _, Route = fresh()
    local dest = { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 }
    local flown = build(Route, P(1, 0.1, 0.1), dest)
    H.assertEq(flown[1].kind, "taxi", "flying is fastest")
    local steps, total = build(Route, P(1, 0.1, 0.1), dest, { avoid = { taxi = true } })
    H.assertEq(steps[1].kind, "travel", "walks when flights are avoided")
    H.assertTrue(total < 3600, "no penalty in the time shown: " .. tostring(total))
end

-- With nothing else that gets there, an avoided way is still taken, and
-- its time is its own.
function tests.avoid_stillTakenWhenNothingElseGetsThere()
    local _, ns, Route = fresh()
    withNav(ns, function() return nil end)
    local d = data()
    d.edges, d.abilities = {}, {}
    local steps, total = build(Route, P(1, 0.1, 0.1), { name = "Far corner", mapID = 1, x = 0.9, y = 0.9 },
                               { data = d, avoid = { taxi = true } })
    H.assertEq(steps[1].kind, "taxi", "the flight is the only way")
    H.assertTrue(total < 3600, "no penalty in the time shown: " .. tostring(total))
end

-- Hops this account has flown count over the estimate from their length.
function tests.flown_hopsCountOverTheEstimate()
    local _, _, Route = fresh()
    local dest = { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 }
    local _, estimated = build(Route, P(1, 0.1, 0.1), dest)
    local _, flown = build(Route, P(1, 0.1, 0.1), dest, { flown = function() return 30 end })
    H.assertTrue(flown < estimated - 200, "two 30 s hops beat two 200 s estimates: " .. flown .. " vs " .. estimated)
end

-- A boat whose route a ride has timed waits for its next departure, not
-- half its loop; one not timed keeps the average.
function tests.boat_timedWaitsForItsNextDeparture()
    local _, _, Route = fresh()
    local d = data()
    d.abilities, d.legs = {}, {}
    d.edges = { { kind = "boat", n = "Boat to Map 2", dest = "Map 2", from = P(1, 0.1, 0.12), to = P(2, 0.5, 0.59),
                  sec = 60, wait = 150, route = 7, stop = 1 } }
    local dest = { name = "Pier", mapID = 2, x = 0.5, y = 0.6 }
    local _, average = build(Route, P(1, 0.1, 0.12), dest, { data = d })
    local steps, timed = build(Route, P(1, 0.1, 0.12), dest, { data = d, waitAt = function() return 20 end })
    H.assertTrue(math.abs((average - timed) - 130) < 2, "20 s instead of 150: " .. average .. " vs " .. timed)
    local boat
    for i = 1, #steps do if steps[i].kind == "boat" then boat = steps[i] end end
    H.assertEq(boat.wait, 20)
    H.assertTrue(boat.live, "the step says its wait is live")
end

-- A character as the client has it: riding spells known, mounts owned
-- ({ mount type, hidden on this character }), the zone's flying.
local function rider(env, spells, mounts, zone)
    local known = {}
    for _, s in ipairs(spells) do known[s] = true end
    env.IsPlayerSpell = function(s) return known[s] or false end
    env.C_MountJournal = {
        GetMountIDs = function()
            local ids = {}
            for i = 1, #mounts + 1 do ids[i] = i end   -- one not collected
            return ids
        end,
        GetMountInfoByID = function(id)
            local m = mounts[id]
            return "Mount " .. id, id, 0, false, true, 0, false, false, nil, m and m[2] or false, m ~= nil
        end,
        GetMountInfoExtraByID = function(id) return nil, "", "", false, mounts[id] and mounts[id][1] or 230 end,
    }
    zone = zone or {}
    env.IsFlyableArea = function() return zone.fly or false end
    env.IsAdvancedFlyableArea = function() return zone.sky or false end
    env.C_UnitAuras = { GetPlayerAuraBySpellID = function(s) return (zone.steady and s == 404468) and {} or nil end }
end

-- The 1.x game: a mount owned, the riding it needs known, at that mount's
-- pace; a level says nothing.
function tests.riding_foreverByMountsAndSkill()
    local d = data()
    d.classic = true
    local cases = {
        { "no riding, a horse owned", {}, { { 469 } }, 7 },
        { "apprentice and horse riding, a horse", { 33388, 824 }, { { 469 } }, 11.2 },
        { "apprentice, a swift horse only", { 33388, 824 }, { { 470 } }, 7 },
        { "journeyman, a horse and a swift horse", { 33388, 33391, 824 }, { { 469 }, { 470 } }, 14 },
        { "apprentice, a ram without ram riding", { 33388, 824 }, { { 459 } }, 7 },
        { "a warlock's felsteed, no riding", {}, { { 471 } }, 11.2 },
        { "the other side's mount", { 33388, 825 }, { { 455, true } }, 7 },
    }
    for _, c in ipairs(cases) do
        local env, _, Route = fresh()
        rider(env, c[2], c[3])
        local ground, fly = Route.Riding(d)
        H.assertTrue(math.abs(ground - c[4]) < 0.01, c[1] .. ": " .. ground)
        H.assertEq(fly, nil, c[1] .. ": no flying")
    end
end

-- Retail: flying where the zone lets this character, skyriding at the
-- recorded pace, steady flight at its riding's.
function tests.riding_retailFliesWhereItCan()
    local d = data()
    local function ride(spells, mounts, zone)
        local env, _, Route = fresh()
        rider(env, spells, mounts, zone)
        return Route.Riding(d)
    end
    local sky = { 33388, 33391, 34090, 90265, 376777 }
    local _
    local ground, fly = ride(sky, { { 424 } }, { fly = true, sky = true })
    H.assertTrue(math.abs(ground - 14) < 0.01, "ground at 100%: " .. ground)
    H.assertEq(fly, d.speeds.fly, "skyriding: the recorded pace")
    _, fly = ride(sky, { { 424 } }, { fly = true, sky = true, steady = true })
    H.assertTrue(math.abs(fly - 36.4) < 0.01, "steady at master riding, 420%: " .. tostring(fly))
    -- A no-fly spot (a city, a building) grounds only a trip inside its map.
    local here
    _, fly, here = ride(sky, { { 424 } }, { fly = false })
    H.assertEq(fly, d.speeds.fly, "standing in a no-fly city: still flies elsewhere")
    H.assertFalse(here, "and cannot take off here")
    local env, _, Route = fresh()
    rider(env, sky, { { 424 } })
    local city, other = { m = 2393 }, { m = 2395 }
    H.assertTrue(Route.TripFlies(fly, false, city, other), "leaving the no-fly city: flies")
    H.assertFalse(Route.TripFlies(fly, false, city, { m = 2393 }), "across the city's own streets: on foot")
    H.assertTrue(Route.TripFlies(fly, true, city, { m = 2393 }), "a flyable map: flies within it")
    H.assertFalse(Route.TripFlies(nil, true, city, other), "no flying mount: on foot")
    _, fly = ride(sky, { { 230 } }, { fly = true, sky = true })
    H.assertEq(fly, nil, "a ground mount only")
    _, fly = ride({ 33388, 33391 }, { { 424 } }, { fly = true, sky = true, steady = true })
    H.assertEq(fly, nil, "steady style without expert riding")
    ground = ride({}, { { 284 } })
    H.assertTrue(math.abs(ground - 11.2) < 0.01, "chauffeured, no riding: " .. ground)
end

-- MoP Classic flies per continent by the game's own licenses: Kalimdor and
-- the Eastern Kingdoms want Flight Master's License, Outland riding alone.
-- GPS once took every MoP character for one who could not fly at all.
function tests.riding_mistsLicensePerContinent()
    local d = data()
    d.classic = true
    local function ride(spells, map)
        local env, ns, Route = fresh(function(e)
            e.GetInstanceInfo = function() return "World", "none", 0, "", 5, 0, false, map end
        end)
        ns.Caps = { classic = true, mists = true }
        rider(env, spells, { { 248 } }, { fly = true })
        return Route.Riding(d)
    end
    local expert = { 33388, 33391, 34090 }
    local _, fly = ride(expert, 1)
    H.assertNil(fly, "Kalimdor without the license: no flying")
    _, fly = ride({ 33388, 33391, 34090, 90267 }, 1)
    H.assertTrue(fly and math.abs(fly - 17.5) < 0.01, "with it, expert riding's 150%: " .. tostring(fly))
    _, fly = ride(expert, 530)
    H.assertTrue(fly and math.abs(fly - 17.5) < 0.01, "Outland wants no license")
    local ground = ride(expert, 1)
    H.assertTrue(math.abs(ground - 14) < 0.01, "on the ground at 100%: " .. ground)
end

-- Anniversary ships no mount tables: Expert or Artisan riding flies in
-- Outland's air, nowhere else.
function tests.riding_tbcFliesInOutland()
    local d = data()
    d.classic = true
    local function ride(spells, map)
        local env, ns, Route = fresh(function(e)
            e.GetInstanceInfo = function() return "World", "none", 0, "", 5, 0, false, map end
        end)
        ns.Caps = { classic = true, tbc = true }
        rider(env, spells, {}, { fly = true })
        return Route.Riding(d)
    end
    local _, fly = ride({ 33388, 33391, 34090 }, 530)
    H.assertTrue(fly and math.abs(fly - 17.5) < 0.01, "expert: 150%")
    _, fly = ride({ 33388, 33391, 34090, 34091 }, 530)
    H.assertTrue(fly and math.abs(fly - 26.6) < 0.01, "artisan: 280%")
    _, fly = ride({ 33388, 33391, 34090 }, 1)
    H.assertNil(fly, "Kalimdor: no flying on Anniversary")
end

-- The journal walks once; a mount learned walks it again.
function tests.riding_mountLearnedRereads()
    local frames = {}
    local env, _, Route = fresh(function(e)
        e.C_EventUtils = { IsEventValid = function() return true end }
        local make = e.CreateFrame
        e.CreateFrame = function(...)
            local f, events = make(...), {}
            f.RegisterEvent = function(_, ev) events[ev] = true end
            f._events = events
            frames[#frames + 1] = f
            return f
        end
    end)
    local d = data()
    d.classic = true
    local mounts = {}
    rider(env, { 33388, 824 }, mounts)
    H.assertEq(Route.Riding(d), 7, "nothing owned")
    mounts[1] = { 469 }
    H.assertEq(Route.Riding(d), 7, "held until the journal changes")
    for _, f in ipairs(frames) do
        if f._events.NEW_MOUNT_ADDED then f._handlers.OnEvent(f, "NEW_MOUNT_ADDED") end
    end
    H.assertTrue(math.abs(Route.Riding(d) - 11.2) < 0.01, "the new horse")
end

-- A report: one line the dev replay reads back, every field in its place.
function tests.report_isOneLineOfEveryField()
    local env, ns, Route = fresh()
    local d = data()
    d.classic = true
    ns.GPSData = d
    Route.recordedKnown = { [1] = true, [2] = true, [3] = true, [7] = true }
    env.GetBuildInfo = function() return "1.60.1", "70170" end
    env.UnitFactionGroup = function() return "Alliance" end
    env.UnitRace = function() return "Human", "Human" end
    env.UnitClass = function() return "Warrior", "WARRIOR" end
    env.UnitLevel = function() return 60 end
    env.C_Item = { GetItemCount = function(id) return id == 6948 and 1 or 0 end }
    local dest = { name = "Far corner", mapID = 1, x = 0.9, y = 0.91 }
    local steps, total = buildAll(Route, P(1, 0.1, 0.11), dest, { data = d })
    local route = { dest = dest, steps = steps, tookSec = 300,
                    report = { from = { ci = 1, wx = 1000, wy = 1100, m = 1, x = 0.1, y = 0.11 }, total = total, fly = false, re = 1,
                               steps = Route.StepsCode(steps) } }
    local code = Route.ReportCode(route, { version = "3.5.0", avoid = { boat = true, taxi = false },
                                           hearth = { m = 1, x = 0.5, y = 0.5 } })
    local function has(part) H.assertTrue(code:find(part, 1, true) ~= nil, part .. " in " .. code) end
    -- Level 60, never seen riding: planned on foot (a level owns no mount).
    has("efgps1 v=3.5.0 g=forever b=70170 f=Alliance r=Human c=WARRIOR lvl=60 fly=0 spd=7.0 ")
    has(" from=1:0.1000:0.1100 at=1:1000.0:1100.0 to=1:0.9000:0.9100 av=boat hs=1:0.5000:0.5000 kn=1-3.7 ")
    has(" eta=" .. math.floor(total + 0.5) .. " took=300 re=1 ")
    H.assertTrue(code:find(" st=travel>1/%d+,taxi:1%-3>1/%d+,travel>1/%d+ ") ~= nil, "the steps in " .. code)
    H.assertEq(code:sub(-13), " n=Far corner", "the name comes last")
    has(" own=i6948 ")
end

-- A crossing whose own spot the grid cannot walk to (a boat's stop out on
-- the water) is boarded from the ground just around it.
function tests.crossingOffTheGround_isBoardedFromNearby()
    local _, ns, Route = fresh()
    local function nearPortal(x, y) return math.abs(x - 5000) < 2 and math.abs(y - 5000) < 2 end
    withNav(ns, function(sx, sy, tx, ty)
        if nearPortal(sx, sy) or nearPortal(tx, ty) then return nil end
        return { sx, sy, tx, ty }
    end)
    local d = data()
    d.edges = { d.edges[1] }
    d.abilities, d.legs = {}, {}
    local steps = build(Route, P(1, 0.49, 0.49), { name = "Over there", mapID = 2, x = 0.5, y = 0.53 }, { data = d })
    H.assertNotNil(steps, "a route through the portal")
    H.assertEq(steps[1].kind, "portal")
end

-- A walk no foot can take in the middle is never chosen: the crossing is.
function tests.unwalkableMiddle_isNeverChosen()
    local _, ns, Route = fresh()
    withNav(ns, function(sx, sy, tx, ty)
        -- Nothing on foot crosses the x = 5000 line.
        if (sx - 5000) * (tx - 5000) < 0 then return nil end
        return { sx, sy, tx, ty }
    end)
    local steps, total = buildAll(Route, P(1, 0.1, 0.1), { name = "Far side", mapID = 1, x = 0.9, y = 0.9 })
    H.assertNotNil(steps)
    H.assertTrue(total < math.huge, "finite: " .. tostring(total))
    for i = 1, #steps do H.assertTrue((steps[i].sec or 0) < math.huge, "step " .. i .. " is finite") end
end

-- The report line never fails on a time it cannot hold.
function tests.stepsCode_neverFailsOnAnEndlessTime()
    local _, _, Route = fresh()
    local code = Route.StepsCode({ { kind = "travel", sec = math.huge, arrive = { m = 1439 } } })
    H.assertEq(code, "travel>1439/-1")
end

local pass, fail, failures = H.runSuite("GPSRoute", tests)
return { pass = pass, fail = fail, failures = failures }
