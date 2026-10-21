-- Tests for Apps/GPS/Nav.lua on a real two-tile bake of Elwynn Forest
-- (tests/fixtures/nav_elwynn.lua, packed by dev/tools/navmesh/pack.py):
-- walks across the tiles' seam, drawn paths that keep to walkable cells,
-- and the floor under a point.
local H = require("Harness")
local Inflate = require("Inflate")

local function fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = true }
    env.C_EncodingUtil = { DecodeBase64 = Inflate.DecodeBase64, DecompressString = function(s) return Inflate.Raw(s) end }
    H.loadModule("tests/fixtures/nav_elwynn.lua", env, ns)
    H.loadModule("Apps/GPS/Nav.lua", env, ns)
    return ns.GPSNav
end

-- Goldshire's crossroads (tile 31,49) and a meadow in the tile east of it.
local GOLDSHIRE = { -9465, 64 }
local EAST = { -9300, -300 }

local function Straight(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end

local tests = {}

function tests.walk_acrossTheTileSeam()
    local Nav = fresh()
    local cost = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local straight = Straight(GOLDSHIRE, EAST)
    H.assertTrue(cost ~= nil, "a way on foot between the tiles")
    H.assertTrue(cost >= straight - 8, "never shorter than the straight line: " .. cost .. " vs " .. straight)
    H.assertTrue(cost <= straight * 1.6, "no wild detour over open ground: " .. cost .. " vs " .. straight)
end

function tests.walk_sameBothWays()
    local Nav = fresh()
    local there = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local back = Nav.Walk(0, EAST[1], EAST[2], GOLDSHIRE[1], GOLDSHIRE[2])
    H.assertTrue(math.abs(there - back) <= there * 0.03, "within 3%: " .. there .. " and " .. back)
end

function tests.path_endsWhereAsked()
    local Nav = fresh()
    local pts = Nav.Path(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    H.assertTrue(pts ~= nil and #pts >= 4)
    H.assertDeepEq({ pts[1], pts[2] }, GOLDSHIRE, "starts at the start")
    H.assertDeepEq({ pts[#pts - 1], pts[#pts] }, EAST, "ends at the goal")
end

-- Every stretch of the drawn line lies over walkable cells (each sample's
-- own cell has a floor; the ends may stand a step off the grid).
function tests.path_keepsToWalkableGround()
    local Nav = fresh()
    local pts = Nav.Path(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local off = 0
    for v = 3, #pts - 2, 2 do
        local ax, ay, bx, by = pts[v - 2], pts[v - 1], pts[v], pts[v + 1]
        local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
        for k = 1, math.floor(len / 2) do
            local t = k * 2 / len
            if not select(2, Nav.Probe(0, ax + t * (bx - ax), ay + t * (by - ay), false, true)) then off = off + 1 end
        end
    end
    H.assertEq(off, 0, "samples off walkable cells")
end

-- Each stretch of a drawn walk is one the player walks straight along.
function tests.straight_alongEachDrawnStretch()
    local Nav = fresh()
    local pts = Nav.Path(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    for v = 3, #pts - 5, 2 do
        H.assertEq(Nav.Straight(0, pts[v], pts[v + 1], pts[v + 2], pts[v + 3]), true,
            "stretch from point " .. ((v + 1) / 2))
    end
end

function tests.straight_notOffTheBakedGround()
    local Nav = fresh()
    local _, sx, sy = Nav.TileOf(GOLDSHIRE[1], GOLDSHIRE[2])
    -- A tile further west than the fixture holds.
    H.assertEq(Nav.Straight(0, GOLDSHIRE[1], GOLDSHIRE[2], GOLDSHIRE[1], sy + 700), false)
    H.assertTrue(sx ~= nil)
end

-- The pulled line is no longer than the walk it was priced as.
function tests.path_noLongerThanItsCost()
    local Nav = fresh()
    local pts, cost = Nav.Path(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local len = 0
    for v = 3, #pts, 2 do len = len + math.sqrt((pts[v] - pts[v - 2]) ^ 2 + (pts[v + 1] - pts[v - 1]) ^ 2) end
    H.assertTrue(len <= cost + 8, "drawn " .. len .. ", priced " .. cost)
    H.assertTrue(len >= Straight(GOLDSHIRE, EAST) - 1)
end

-- A walk's time (yards walked, swimming slower) comes with its cost: never
-- more than the cost (leaving a road weighs the choice, not the clock),
-- never less than the straight line, and the drawn way's time is the same.
function tests.walk_timeComesWithTheCost()
    local Nav = fresh()
    local cost, beyond, time = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    H.assertNil(beyond)
    H.assertTrue(time ~= nil and time <= cost + 0.01, "the time within the cost: " .. tostring(time) .. " vs " .. cost)
    H.assertTrue(time >= Straight(GOLDSHIRE, EAST) - 8, "no shorter than the straight line: " .. time)
    local _, drawnCost, drawnTime = Nav.Path(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    H.assertEq(drawnCost, cost)
    H.assertEq(drawnTime, time, "the drawn way's time is the walk's")
    Nav.SetRoads(true)
    local roadsCost, _, roadsTime = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    H.assertTrue(roadsTime <= roadsCost + 0.01 and roadsTime >= time - 0.01,
        "kept to roads: a dearer choice, a way no quicker: " .. roadsTime .. " vs " .. time)
    Nav.SetRoads(false)
end

-- A tile to go around costs more to choose; the walk keeps out of it where
-- it can, its time the walk's own, and all is as before once no tile is.
function tests.danger_weighsTheChoiceNotTheTime()
    local Nav = fresh()
    local cost = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local _, _, time = Nav.Path(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local key = Nav.TileOf(EAST[1], EAST[2])
    Nav.SetDanger({ [0] = { [key] = true } })
    local wary = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local _, waryCost, waryTime = Nav.Path(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    H.assertTrue(wary > cost * 1.2, "the dangerous tile weighs: " .. wary .. " vs " .. cost)
    H.assertTrue(math.abs(waryCost - wary) < 1, "the drawn walk is the one chosen")
    H.assertTrue(waryTime >= time - 1 and waryTime < wary / 2,
        "the time is the walk's own, not its weight: " .. waryTime .. " (was " .. time .. ", weight " .. wary .. ")")
    Nav.SetDanger(nil)
    H.assertTrue(math.abs(Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2]) - cost) < 0.01, "and back")
end

-- Staying on roads: its own tile costs and weights; ground off a road
-- costs more to choose, and all is as before once it is off again.
function tests.roads_weighOffRoadGround()
    local Nav = fresh()
    H.assertTrue(Nav.HasRoads(0), "the data carries the roads costs")
    local cost = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    Nav.SetRoads(true)
    local roads = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local pts, pathCost = Nav.Path(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    H.assertTrue(roads > cost, "off-road ground weighs more: " .. roads .. " vs " .. cost)
    H.assertTrue(pts ~= nil and math.abs(pathCost - roads) < 1, "the drawn walk is the one chosen")
    Nav.SetRoads(false)
    H.assertTrue(math.abs(Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2]) - cost) < 0.01, "and back")
end

-- A drop goes one way: off a 7 yd ledge in one step, back up the long way
-- round (the fixture is baked with safe drops up to 10 yd, survived 15).
local LEDGE, BELOW = { -9185.0, -310.8 }, { -9181.0, -310.8 }

function tests.drop_oneWayDown()
    local Nav = fresh()
    local down = Nav.Walk(0, LEDGE[1], LEDGE[2], BELOW[1], BELOW[2])
    local up = Nav.Walk(0, BELOW[1], BELOW[2], LEDGE[1], LEDGE[2])
    H.assertTrue(down ~= nil and down < 20, "off the ledge in a step: " .. tostring(down))
    H.assertTrue(up ~= nil and up > 200, "back up the long way: " .. tostring(up))
    local pts = Nav.Path(0, LEDGE[1], LEDGE[2], BELOW[1], BELOW[2])
    H.assertTrue(pts ~= nil and #pts <= 8, "the drawn walk is the drop")
end

-- Searched from its end, a walk costs what it does the way it is walked:
-- inside a tile and across the seam.
function tests.reverse_pricesTheWayItIsWalked()
    local Nav = fresh()
    local down = Nav.Walk(0, LEDGE[1], LEDGE[2], BELOW[1], BELOW[2])
    local back = Nav.Walk(0, BELOW[1], BELOW[2], LEDGE[1], LEDGE[2], { reverse = true })
    H.assertTrue(math.abs(down - back) < 1, "off the ledge either way it is searched: " .. down .. " and " .. back)
    local there = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local fromEnd = Nav.Walk(0, EAST[1], EAST[2], GOLDSHIRE[1], GOLDSHIRE[2], { reverse = true })
    H.assertTrue(math.abs(there - fromEnd) < 1, "across the seam: " .. there .. " and " .. fromEnd)
    H.assertNil(Nav.Path(0, BELOW[1], BELOW[2], LEDGE[1], LEDGE[2], { reverse = true }), "drawn only the way walked")
end

function tests.dropLimit_aTallerLedgeIsAShortcutOnlyWhenAllowed()
    local Nav = fresh()
    local top, below = { -9140.9, -210.5 }, { -9136.8, -210.5 }   -- a 15 yd ledge
    H.assertEq(Nav.DropHeights(0), 10)
    local safe = Nav.Walk(0, top[1], top[2], below[1], below[2])
    local _, _, _, none = Nav.Path(0, top[1], top[2], below[1], below[2])
    local epoch = Nav.epoch
    Nav.SetDropLimit(15)
    H.assertTrue(Nav.epoch ~= epoch, "walks kept under the old limit are told apart")
    local survive = Nav.Walk(0, top[1], top[2], below[1], below[2])
    local _, _, _, jumps = Nav.Path(0, top[1], top[2], below[1], below[2])
    Nav.SetDropLimit(nil)
    H.assertTrue(safe > survive + 20, "around at the safe limit: " .. tostring(safe) .. " vs " .. tostring(survive))
    H.assertEq(#none, 0, "no jump the limit does not allow")
    H.assertEq(#jumps, 1, "the jump is reported")
    H.assertTrue(jumps[1].h > 14 and jumps[1].h < 16, "with its height")
    H.assertEq(Nav.Walk(0, top[1], top[2], below[1], below[2]), safe, "back to the safe limit")
    H.assertEq(Nav.epoch, epoch)
end

function tests.dropLimit_anyHeightTakesTheTallestLevel()
    local Nav = fresh()
    local top, below = { -9136.8, -202.5 }, { -9132.8, -202.5 }   -- a 16.8 yd ledge
    Nav.SetDropLimit(15)
    local survive = Nav.Walk(0, top[1], top[2], below[1], below[2])
    Nav.SetDropLimit(math.huge)
    local any = Nav.Walk(0, top[1], top[2], below[1], below[2])
    H.assertTrue(any ~= nil and survive ~= nil and any < survive, "past what a fall lets one live through")
end

-- A swimmer comes ashore where the bank slopes into the water (no step to
-- climb: the feet touch); without the shore links it swam 480 yd round.
function tests.walk_swimmerComesAshoreOnASlopingBank()
    local Nav = fresh()
    local cost = Nav.Walk(0, -9365.4, 515.3, -9357.4, 515.3)
    H.assertTrue(cost ~= nil and cost < 20, "out of the water onto the bank: " .. tostring(cost))
end

-- A cell with ground and the water's surface: a point stands on the ground.
function tests.locate_takesTheGroundOverTheWater()
    local Nav = fresh()
    local key, g = Nav.Probe(0, -9325.3, -138.3, false, true)
    local t = Nav._worlds[0].tiles[key]
    H.assertTrue(g ~= nil and string.byte(t.fb, g) % 2 == 0, "the ground, not the water")
end

-- An end no side of its tile leads from (a pit a drop leads into): no way
-- out of the tile, only the way inside it, with landmarks too.
function tests.walk_anEndNoSideLeaves_keepsToItsTile()
    local Nav = fresh()
    Nav.SetDropLimit(15)
    local key, g = Nav.Probe(0, GOLDSHIRE[1], GOLDSHIRE[2])
    local w = Nav._worlds[0]
    w.reach[(key * 131072 + g) * 2] = { {}, {} }
    w.alt = { string.rep("\1\0\0", 64) }
    H.assertNil(Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2]), "no way out of the tile")
    local inside = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], GOLDSHIRE[1] + 20, GOLDSHIRE[2])
    H.assertTrue(inside ~= nil and inside < 40, "the way inside it: " .. tostring(inside))
    Nav.SetDropLimit(nil)
end

function tests.walk_noDataNoWalk()
    local Nav = fresh()
    H.assertNil(Nav.Walk(0, -5000, 0, GOLDSHIRE[1], GOLDSHIRE[2]), "a point outside the data")
    H.assertNil(Nav.Walk(1, -9465, 64, -9300, -300), "a continent without data")
    H.assertFalse(Nav.Has(1))
    H.assertTrue(Nav.Has(0))
end

function tests.probe_findsTheFloorUnderAPoint()
    local Nav = fresh()
    local key, floor = Nav.Probe(0, GOLDSHIRE[1], GOLDSHIRE[2])
    H.assertEq(key, 31 * 64 + 49, "Goldshire's tile")
    H.assertTrue(floor ~= nil)
end

-- Inside a plan's slice a search gives the frame back and, resumed, ends
-- where a search run straight through does; outside a plan it never pauses.
function tests.walk_pausesInsideAPlanAndFinishesTheSame()
    local whole = fresh().Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = true }
    env.C_EncodingUtil = { DecodeBase64 = Inflate.DecodeBase64, DecompressString = function(s) return Inflate.Raw(s) end }
    env.debugprofilestop = function() return 1e9 end
    H.loadModule("tests/fixtures/nav_elwynn.lua", env, ns)
    H.loadModule("Apps/GPS/Nav.lua", env, ns)
    local Nav = ns.GPSNav
    local co = coroutine.create(function()
        Nav.yieldCo = coroutine.running()
        local cost = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
        Nav.yieldCo = nil
        return cost
    end)
    local slices, ok, cost = 0
    repeat
        Nav.sliceEnd = 0
        ok, cost = coroutine.resume(co)
        Nav.sliceEnd = nil
        slices = slices + 1
    until coroutine.status(co) == "dead"
    H.assertTrue(ok, tostring(cost))
    H.assertTrue(slices > 1, "it gave the frame back")
    H.assertEq(cost, whole)
    -- Outside the plan's coroutine: straight through.
    Nav.yieldCo, Nav.sliceEnd = co, 0
    H.assertEq(Nav.Walk(0, EAST[1], EAST[2], GOLDSHIRE[1], GOLDSHIRE[2]) ~= nil, true)
end

-- A near end takes the ground around b: never dearer than b itself, and
-- short of it by no more than the reach.
function tests.walk_nearEndTakesTheGroundAroundIt()
    local Nav = fresh()
    local exact = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local near = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2], { near = 40 })
    H.assertTrue(near ~= nil and near <= exact + 0.01, "no dearer: " .. tostring(near) .. " vs " .. exact)
    H.assertTrue(near >= exact - 40 * 1.6, "short by the reach at most: " .. near .. " vs " .. exact)
    -- Across the tiles' seam (y = 0) from a point beside it.
    local across = Nav.Walk(0, -9400, 30, -9400, -15, { near = 40 })
    H.assertTrue(across ~= nil and across < 50, "the ground across the seam: " .. tostring(across))
end

-- A near end drawn: the walk comes to a floor within reach of b, then on
-- to b; its cost is the near walk's.
function tests.path_nearEndStopsWithinReach()
    local Nav = fresh()
    local pts, cost = Nav.Path(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2], { near = 40 })
    H.assertTrue(pts ~= nil and #pts >= 6, "a drawn way")
    H.assertDeepEq({ pts[#pts - 1], pts[#pts] }, EAST, "on to b")
    local fx, fy = pts[#pts - 3], pts[#pts - 2]
    H.assertTrue(Straight({ fx, fy }, EAST) <= 40 + 3, "its last floor within reach")
    H.assertEq(cost, Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2], { near = 40 }))
end

-- Every shipped grid says which entrances one can walk between (ground.py),
-- or a walk with no way searches all the ground it reaches first.
function tests.shippedGrids_carryTheirGround()
    for _, name in ipairs({ "Walk_Kalimdor", "Walk_EasternKingdoms", "Walk_ZephrasIsle" }) do
        local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/" .. name .. ".lua", "rb"))
        f:seek("end", -4096)
        local tail = f:read("*a")
        f:close()
        H.assertTrue(tail:find('ground = "', 1, true) ~= nil, name .. " carries no ground")
    end
end

-- A point on a city street takes the street: a grid keeping ground one
-- only drops into started Stormwind walks under the city.
function tests.shippedGrid_aStreetPointTakesTheStreet()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = true }
    env.C_EncodingUtil = { DecodeBase64 = Inflate.DecodeBase64, DecompressString = function(s) return Inflate.Raw(s) end }
    H.loadModule("Apps/GPS/Walk_EasternKingdoms.lua", env, ns)
    H.loadModule("Apps/GPS/Nav.lua", env, ns)
    local trade, gate = { -8830, 630 }, { -9050, 440 }
    local cost = ns.GPSNav.Walk(0, trade[1], trade[2], gate[1], gate[2])
    H.assertTrue(cost ~= nil and cost < Straight(trade, gate) * 1.8, "along the streets: " .. tostring(cost))
end

-- Decoded data idle for a while goes and comes back on the next walk the
-- same; a tile read since then stays.
function tests.release_letsIdleDataGo_keepsWhatWasRead()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = true }
    env.C_EncodingUtil = { DecodeBase64 = Inflate.DecodeBase64, DecompressString = function(s) return Inflate.Raw(s) end }
    H.loadModule("tests/fixtures/nav_elwynn.lua", env, ns)
    H.loadModule("Apps/GPS/Nav.lua", env, ns)
    local Nav = ns.GPSNav
    local cost = Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local w = Nav._worlds[0]
    H.assertTrue(#w.order > 0 and w.ents ~= nil, "the walk decoded tiles and entrance sides")
    H.assertTrue(Nav.Release(60), "nothing idle yet: held")
    H.assertTrue(#w.order > 0 and w.ents ~= nil, "and kept")
    env._clock:advance(30)
    Nav.Straight(0, GOLDSHIRE[1], GOLDSHIRE[2], GOLDSHIRE[1] + 5, GOLDSHIRE[2])
    env._clock:advance(31)
    H.assertTrue(Nav.Release(60), "the tile read since stays: held")
    H.assertEq(#w.order, 1, "only the tile under the read point")
    H.assertNil(w.ents, "the entrance sides went")
    H.assertNil(w.alt, "the landmarks went")
    env._clock:advance(61)
    H.assertFalse(Nav.Release(60), "all gone")
    H.assertEq(#w.order, 0)
    H.assertEq(Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2]), cost, "the same walk after")
end

-- A route's walks keep the continent in use; a tile's walking costs go
-- on their own once no walk has read them for a minute.
function tests.release_letsATilesCostsGoWhileTheContinentIsInUse()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = true }
    env.C_EncodingUtil = { DecodeBase64 = Inflate.DecodeBase64, DecompressString = function(s) return Inflate.Raw(s) end }
    H.loadModule("tests/fixtures/nav_elwynn.lua", env, ns)
    H.loadModule("Apps/GPS/Nav.lua", env, ns)
    local Nav = ns.GPSNav
    Nav.Walk(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local w = Nav._worlds[0]
    local home, east = Nav.TileOf(GOLDSHIRE[1], GOLDSHIRE[2]), Nav.TileOf(EAST[1], EAST[2])
    H.assertTrue(w.costs[home] and w.costs[east], "the walk read both tiles' costs")
    env._clock:advance(61)
    Nav.Walk(0, EAST[1], EAST[2], EAST[1] + 60, EAST[2] + 40)
    H.assertTrue(Nav.Release(60), "held")
    H.assertNil(w.costs[home], "the idle tile's costs went")
    H.assertTrue(w.costs[east] ~= nil, "the tile walked since keeps its")
    local kept = 0
    for _, end_ in pairs(w.reach) do
        kept = kept + 1
        H.assertTrue(end_.used == env.GetTime(), "only ends the later walk read stay")
    end
    H.assertEq(w.reachN, kept, "the count follows")
    H.assertTrue(w.ents ~= nil, "the continent is still in use")
end

local pass, fail, failures = H.runSuite("GPSNav", tests)
return { pass = pass, fail = fail, failures = failures }
