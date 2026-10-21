-- Tests for the lines under a route (Apps/GPS/GPS.lua AdviceLines): an
-- other way says how much longer it is than the route shown, both as
-- planned; the header's live time runs at the pace seen and is no measure.
local H = require("Harness")

local function Load(db)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local function AdviceLines(route)", 1, true), "AdviceLines not in GPS.lua")
    local _, e = src:find("\nend\r?\n", s)
    local env = setmetatable({
        L = {
            GPS_OTHER_WAY_FMT = "Other way: %s", GPS_WAY_PORTAL_FMT = "%s by portal",
            GPS_WAY_LONGER_FMT = "%s longer", GPS_WAY_SHORTER_FMT = "%s shorter",
            GPS_ADVICE_DETOUR_FMT = "Detour to learn %s? +%s now, then %s faster on trips like this",
            GPS_ADVICE_PICKUP_FMT = "On the way: learn the %s flight path",
        },
        EtaText = function(sec) return math.floor(sec / 60 + 0.5) .. " min" end,
        DB = function() return db or {} end,
        GPS = { StepNear = function() return nil end },
        sformat = string.format,
    }, { __index = _G })
    return assert(load(src:sub(s, e) .. "\nreturn AdviceLines", "=GPS.lua AdviceLines", "t", env))()
end

local tests = {}

-- The route as planned took 35 min; shown live it reads 56 (on foot where
-- a mount was planned). A 55 min portal way is 20 min longer, not faster.
function tests.otherWay_isTheDifferenceAsPlanned()
    local AdviceLines = Load()
    local lines = AdviceLines({ total = 35 * 60, eta = 56 * 60, others = { { way = "portal", total = 55 * 60 } } })
    H.assertEq(lines[1].text, "Other way: 20 min longer by portal")
end

function tests.otherWay_shorterWhenTheRouteWasForcedAway()
    local AdviceLines = Load()
    local lines = AdviceLines({ total = 40 * 60, others = { { way = "portal", total = 30 * 60 } } })
    H.assertEq(lines[1].text, "Other way: 10 min shorter by portal")
end

-- The route menu's switches: detours off hides every flight path to learn,
-- on the way or off it; the other ways stay.
function tests.detourOff_leavesTheOtherWays()
    local route = { total = 40 * 60, others = { { way = "portal", total = 30 * 60 } },
                    advice = { pickups = { { id = 7, name = "Morgan's Wall" } },
                               learn = { id = 9, name = "Astranaar", extra = 120, save = 300 } } }
    local lines = Load()(route)
    H.assertEq(#lines, 3, "the one on the way, the detour, then the other way")
    H.assertEq(lines[1].id, 7, "on the way first")
    H.assertTrue(lines[2].detour, "then the detour")
    lines = Load({ gpsShowDetours = false })(route)
    H.assertEq(#lines, 1)
    H.assertEq(lines[1].text, "Other way: 10 min shorter by portal")
end

local pass, fail, failures = H.runSuite("GPSAdviceLines", tests)
return { pass = pass, fail = fail, failures = failures }
