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

-- The pulled line is no longer than the walk it was priced as.
function tests.path_noLongerThanItsCost()
    local Nav = fresh()
    local pts, cost = Nav.Path(0, GOLDSHIRE[1], GOLDSHIRE[2], EAST[1], EAST[2])
    local len = 0
    for v = 3, #pts, 2 do len = len + math.sqrt((pts[v] - pts[v - 2]) ^ 2 + (pts[v + 1] - pts[v - 1]) ^ 2) end
    H.assertTrue(len <= cost + 8, "drawn " .. len .. ", priced " .. cost)
    H.assertTrue(len >= Straight(GOLDSHIRE, EAST) - 1)
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

local pass, fail, failures = H.runSuite("GPSNav", tests)
return { pass = pass, fail = fail, failures = failures }
