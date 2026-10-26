-- Stops to learn flight masters (Apps/GPS/GPS.lua AddStop, ViaLeft),
-- 2026-10-26 on TBC: taking Tarren Mill on the other way chosen replanned
-- the trip on the first way (the chosen way dropped) and dropped any stop
-- before it. A stop joins the others where the trip meets it.
local H = require("Harness")

local function Load(route)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function GPS.ViaLeft(route, learned)", 1, true))
    local a = assert(src:find("function GPS:AddStop(tip)", s, true))
    local _, e = src:find("\nend\r?\n", a)
    local GPS, built = {}, {}
    function GPS:Plan(_, build) build() end
    function GPS:BuildStops(_, via, avoid) built.via, built.avoid = via, avoid end
    local env = setmetatable({ GPS = GPS, ns = { GPSRoute = {} }, Route = function() return route end },
        { __index = _G })
    assert(load(src:sub(s, e), "=GPS.lua stops", "t", env))()
    return GPS, built
end

local function Stop(id, name) return { id = id, name = name, p = { m = 1 } } end

local tests = {}

function tests.aStopKeepsTheWayChosen()
    local zeppelin = { zeppelin = true }
    local GPS, built = Load({ dest = { name = "Ironforge" }, wayAvoid = zeppelin })
    GPS:AddStop({ id = 2, name = "Tarren Mill", p = { m = 1 } })
    H.assertTrue(built.avoid == zeppelin, "planned on the way taken, not the first one")
end

function tests.aStopGoesBeforeTheStopItComesAhead()
    local GPS, built = Load({ dest = { name = "Ironforge" }, via = Stop(2, "Tarren Mill") })
    GPS:AddStop({ id = 1, name = "Undercity", p = { m = 1 }, before = 2 })
    H.assertEq(#built.via, 2, "Tarren Mill stays")
    H.assertEq(built.via[1].name, "Undercity", "met first")
    H.assertEq(built.via[2].name, "Tarren Mill")
end

function tests.aStopPastTheOthersGoesLast()
    local GPS, built = Load({ dest = { name = "Ironforge" }, via = { Stop(1, "Undercity") } })
    GPS:AddStop({ id = 2, name = "Tarren Mill", p = { m = 1 } })
    H.assertEq(built.via[1].name, "Undercity")
    H.assertEq(built.via[2].name, "Tarren Mill")
end

function tests.learnedStopsLeaveTheList()
    local GPS = Load({})
    local left = GPS.ViaLeft({ via = { Stop(1, "Undercity"), Stop(2, "Tarren Mill") } }, { [1] = true })
    H.assertEq(#left, 1)
    H.assertEq(left[1].name, "Tarren Mill")
    H.assertNil(GPS.ViaLeft({ via = Stop(1, "Undercity") }, { [1] = true }), "a stop saved alone, learned")
end

local pass, fail, failures = H.runSuite("GPSStops", tests)
return { pass = pass, fail = fail, failures = failures }
