-- Tests for the warning over a route's steps (Apps/GPS/GPS.lua DangerText):
-- the first walk ahead through ground whose creatures con skull names its
-- zone; none once put away, behind the player, or without the catalog.
local H = require("Harness")

-- Two walks on continent 1: the first 0 to 100 yd east, the second on to
-- 200. skullAt: yards along the second where a skull is met.
local function Load(skullAt)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("-- The warning that the route ahead walks through ground", 1, true), "DangerText not in GPS.lua")
    local e = assert(src:find("-- The client's red", s, true), "end of DangerText not found")
    local state = { drawn = true, catalog = true }
    local walks = {}
    local GPS = {}
    local ns = {
        GPSFollow = {
            StartOf = function(route, i) local p = i > 1 and route.steps[i - 1].arrive or route.from return p.ci, p.wx, p.wy end,
            World = function(p) return p.ci, p.wx, p.wy end,
        },
        GPSRoute = {
            WalkPath = function(_, sx)
                if not state.drawn then return nil end
                walks[sx] = walks[sx] or { sx = sx }
                return walks[sx]
            end,
        },
        GPSNpcs = {
            DeadlyAlong = function(path, _, level)
                if not state.catalog then return nil end
                state.asked = (state.asked or 0) + 1
                if path.sx == 100 and skullAt and level < 30 then return { n = 2, 0, 100, skull = skullAt, sx = 100 + skullAt, sy = 0 } end
                return { n = 0 }
            end,
        },
    }
    local env = setmetatable({
        GPS = GPS, ns = ns, sformat = string.format,
        L = { GPS_DANGER = "Deadly." },
        UnitLevel = function() return state.level or 15 end,
        UnitFactionGroup = function() return "Alliance" end,
        ZoneAt = function(_, x) return 400, x >= 100 and "Thousand Needles" or "The Barrens" end,
    }, { __index = _G })
    assert(load(src:sub(s, e - 1), "=GPS.lua DangerText", "t", env))()
    local function Walk(x) return { kind = "travel", arrive = { ci = 1, wx = x, wy = 0 } } end
    local route = { from = { ci = 1, wx = 0, wy = 0 }, steps = { Walk(100), Walk(200) }, active = 1 }
    return GPS, route, state
end

local tests = {}

function tests.skullGroundAhead_warnsWithNoZoneNamed()
    local GPS, route = Load(30)
    H.assertEq(GPS.DangerText(route), "Deadly.")
end

function tests.noSkullGround_noWarning()
    local GPS, route = Load(nil)
    H.assertNil(GPS.DangerText(route))
end

function tests.putAwayOrBehind_noWarning()
    local GPS, route = Load(30)
    route.dangerSeen = true
    H.assertNil(GPS.DangerText(route), "put away for the trip")
    route.dangerSeen = nil
    route.steps[3] = { kind = "travel", arrive = { ci = 1, wx = 300, wy = 0 } }
    route.active = 3
    H.assertNil(GPS.DangerText(route), "the deadly walk is behind")
end

function tests.walksNotDrawn_askedAgainOnceTheyAre()
    local GPS, route, state = Load(30)
    state.drawn = false
    H.assertNil(GPS.DangerText(route), "nothing to read yet")
    state.drawn = true
    H.assertEq(GPS.DangerText(route), "Deadly.")
end

function tests.keptUntilTheLevelChanges()
    local GPS, route, state = Load(30)
    GPS.DangerText(route)
    local asked = state.asked
    GPS.DangerText(route)
    H.assertEq(state.asked, asked, "read once for these steps")
    state.level = 30
    H.assertNil(GPS.DangerText(route), "at 30 nothing there cons skull")
end

function tests.withoutTheCatalog_noWarning()
    local GPS, route, state = Load(30)
    state.catalog = false
    H.assertNil(GPS.DangerText(route))
end

local pass, fail, failures = H.runSuite("GPSDanger", tests)
return { pass = pass, fail = fail, failures = failures }
