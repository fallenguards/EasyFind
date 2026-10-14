-- Tests for Apps/GPS/Minimap.lua: the route on the minimap, cut at the rim
-- and around the player's arrow, the part already walked faded, turning
-- with a turning minimap, and nothing drawn again while standing still.
local H = require("Harness")

local PASSED, BLUE = { 0.7, 0.7, 0.7 }, { 0, 0, 1 }

-- A walk planned 100 yd south of the player to 300 yd north of them, the
-- player on it; a minimap 100 px wide showing 100 yd each way.
local function fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    local now = { t = 100 }
    env.GetTime = function() return now.t end
    local state = { rotate = false, facing = 0 }
    env.Minimap = H.newFrame()
    env.C_Minimap = { GetViewRadius = function() return 100 end }
    env.GetCVarBool = function() return state.rotate end
    env.GetPlayerFacing = function() return state.facing end
    -- World x north, y west; the map's up is north and its left west.
    env.C_Map = { GetBestMapForUnit = function() return 7 end }
    local route = { steps = { { kind = "travel", go = { ci = 1, wx = 300, wy = 0 } } }, active = 1,
                    from = { ci = 1, wx = -100, wy = 0 } }
    ns.GPS = {
        CurrentRoute = function() return route end,
        PlayerWorldPos = function() return 1, 0, 0 end,
    }
    ns.GPSRoute = {
        WorldPos = function(_, mx, my) return 1, (0.5 - my) * 1000, (0.5 - mx) * 1000 end,
        WalkPath = function(_, sx, sy, tx, ty)
            local len = math.sqrt((tx - sx) ^ 2 + (ty - sy) ^ 2)
            return { pts = { sx, sy, tx, ty }, cum = { 0, len }, len = len }
        end,
    }
    local drawn = { calls = 0 }
    local lines = {
        Begin = function() drawn.pieces = {} end,
        Line = function(_, src, m, _, _, color)
            drawn.calls = drawn.calls + 1
            local pts = {}
            for i = 1, m do pts[i] = src[i] end
            drawn.pieces[#drawn.pieces + 1] = { pts = pts, color = color }
        end,
        Finish = function() end,
        Hide = function() drawn.pieces = {} end,
    }
    ns.GPSPreview = {
        NewLines = function() return lines end,
        Span = function() return 10 end,
        PASSED_COLOR = PASSED, PASSED_ALPHA = 0.5, LineColor = function() return BLUE end,
    }
    H.loadModule("Apps/GPS/Follow.lua", env, ns)
    H.loadModule("Apps/GPS/Minimap.lua", env, ns)
    ns.GPSMinimap:Refresh()
    return drawn, state, now, ns.GPSMinimap
end

local function near(a, b) return math.abs(a - b) < 1e-6 end

-- Half the minimap is 50 px; the line 7 px wide stops 4.5 px inside it.
local RIM = 50 - 3.5 - 1

local tests = {}

function tests.walkedPartFadedAndTheWayAheadInBlue()
    local drawn = fresh()
    H.assertEq(#drawn.pieces, 2)
    local behind, ahead = drawn.pieces[1], drawn.pieces[2]
    H.assertTrue(behind.color == PASSED, "the part behind is faded")
    H.assertTrue(ahead.color == BLUE, "the way ahead in blue")
    -- South of the player is down the minimap, north up.
    local b, a = behind.pts, ahead.pts
    H.assertTrue(near(b[1], 0) and near(b[2], -RIM), "from the rim: " .. b[1] .. "," .. b[2])
    H.assertTrue(near(b[#b - 1], 0) and near(b[#b], -7), "to the player's arrow, short of it")
    H.assertTrue(near(a[1], 0) and near(a[2], 7), "on past the arrow")
    H.assertTrue(near(a[#a - 1], 0) and near(a[#a], RIM), "up to the rim")
end

function tests.aTurningMinimapTurnsTheLine()
    local drawn, state, now, Mini = fresh()
    -- Facing west: west is up, so north lies to the right.
    state.rotate, state.facing = true, math.pi / 2
    now.t = now.t + 1
    Mini._Draw()
    local a = drawn.pieces[2].pts
    H.assertTrue(near(a[1], 7) and near(a[2], 0), "on to the right: " .. a[1] .. "," .. a[2])
    H.assertTrue(near(a[#a - 1], RIM) and near(a[#a], 0))
end

function tests.standingStillDrawsNothingAgain()
    local drawn, _, now, Mini = fresh()
    local calls = drawn.calls
    now.t = now.t + 1
    Mini._Draw()
    H.assertEq(drawn.calls, calls, "the same spot, the same drawing")
end

local pass, fail, failures = H.runSuite("GPSMinimap", tests)
return { pass = pass, fail = fail, failures = failures }
