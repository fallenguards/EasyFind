-- Tests for Apps/GPS/Route.lua: straight travel, flight legs folding into
-- one flight, a portal across continents, a teleport from the start, and
-- faction-locked transport.
local H = require("Harness")

-- Two continents: map 1 is continent 1, map 2 is continent 2. Map units
-- are 10000 yards square so distances are easy to read.
local function fresh()
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

-- Every step, the ways to a flight master, dock or portal included.
local function buildAll(Route, startPoint, dest, extra)
    local opts = { data = data(), start = startPoint, faction = "Alliance", canFly = false,
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

-- What this character can use: a flight lands only at a discovered flight
-- point, and a flight master not met yet can start a flight (talking to
-- it teaches it), so the route may walk there, learn it and fly on.
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

-- A seam (the continent id changes with no loading screen, as in Khaz
-- Algar's Coreway) is free passage: the route crosses it as plain travel,
-- one step, no portal wording.
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

-- Roads: world x is north, y is west. A road runs west from A to the
-- junction B (which goes on west to D) and turns north to C.
local function roadData()
    local d = data()
    d.roads = { [1] = { nodes = { 0, 0, 0, 1000, 1000, 1000, 0, 2000 },
                        edges = { 1, 2, 1000, 2, 3, 1000, 2, 4, 1000 }, shapes = {} } }
    return d
end

function tests.roads_followTheRoadThroughTheJunction()
    local _, _, Route = fresh()
    local path = Route.RoadPath(roadData(), 1, 0, -50, 1050, 1000)
    H.assertTrue(path ~= nil, "the roads beat the diagonal")
    H.assertEq(#path.pts / 2, 5, "start, A, B, C, end")
    H.assertEq(math.floor(path.len + 0.5), 2100)
    H.assertDeepEq({ path.pts[5], path.pts[6] }, { 0, 1000 }, "through the junction B")
end

function tests.roads_noneOrNoHelpGivesNoPath()
    local _, _, Route = fresh()
    H.assertNil(Route.RoadPath(data(), 1, 0, 0, 500, 500), "no roads in the data")
    H.assertNil(Route.RoadPath(roadData(), 1, 5000, 5000, 5000, 5100), "a short hop needs no road")
end

local pass, fail, failures = H.runSuite("GPSRoute", tests)
return { pass = pass, fail = fail, failures = failures }
